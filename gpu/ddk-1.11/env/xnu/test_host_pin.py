#!/usr/bin/env python3
"""Exercise the actual 0348 pin helper with mocked IOKit ownership/failures.

This host test does not emulate XNU page wiring, caches or GPU access.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[4]
patch = (root / 'xnu/patches/0348-a01core-host-page-pin.patch').read_text()
start = patch.index('+/* Foundation for importing caller memory.')
end = patch.index('\n extern "C" {', start)
actual = '\n'.join(line[1:] for line in patch[start:end].splitlines() if line.startswith('+'))
prefix = r'''
#include <cstdint>
#include <cstdlib>
#include <cassert>
#include <cstddef>
using IOByteCount = uint64_t;
using vm_offset_t = uintptr_t;
static int live_desc, prepared, live_maps, scenario;
static unsigned flush_count;
extern "C" void flush_dcache(vm_offset_t address, unsigned count, int physical) {
  assert(address == 0x101000 && count == 0x1000 && physical == 0); ++flush_count;
}
static void *kernel_task;
static void *current_task() { return (void *)1; }
enum { kIODirectionInOut=1, kIOMemoryPersistent=2, kIOReturnSuccess=0,
       kIOMemoryMapperNone=0, kIOMapAnywhere=0 };
struct IOMemoryMap {
  uint64_t getAddress() { return 0x100000; }
  void release() { --live_maps; delete this; }
};
struct IOMemoryDescriptor {
  static IOMemoryDescriptor *withAddressRange(uint64_t, uint64_t, int, void *) {
    if (scenario == 1) return nullptr;
    ++live_desc; return new IOMemoryDescriptor;
  }
  int prepare() { if (scenario == 2) return 1; ++prepared; return 0; }
  void complete() { --prepared; }
  void release() { --live_desc; delete this; }
  uint64_t getPhysicalSegment(uint64_t off, IOByteCount *span, int) {
    *span = scenario == 3 ? 2048 : 4096;
    return scenario == 4 ? 0x100000000ULL : 0x20000000ULL + off;
  }
  IOMemoryMap *createMappingInTask(void *, int, int) {
    if (scenario == 5) return nullptr;
    ++live_maps; return new IOMemoryMap;
  }
};
#define IONewZero(T,n) ((T *)calloc((n), sizeof(T)))
#define IODelete(p,T,n) free(p)
#define OSSafeReleaseNULL(p) do { if(p) { (p)->release(); (p)=nullptr; } } while(0)
'''
suffix = r'''
int main() {
  assert(!a01gpu_host_pin(0, 0x4000));
  assert(!a01gpu_host_pin(0x4001, 0x4000));
  assert(!a01gpu_host_pin(0x4000, 0x4001));
  assert(!a01gpu_host_pin(0xffffffffffffc000ULL, 0x8000));
  assert(!a01gpu_host_pin(0x4000, 0x08004000));
  for (scenario=1; scenario<=5; ++scenario) {
    assert(!a01gpu_host_pin(0x4000, 0x4000));
    assert(!live_desc && !prepared && !live_maps);
  }
  scenario=0;
  auto *host=a01gpu_host_pin(0x4000,0x8000);
  assert(host && a01gpu_host_size(host)==0x8000);
  assert(a01gpu_host_phys(host,0x1000)==0x20001000);
  assert(!a01gpu_host_phys(host,0x8000));
  assert(a01gpu_host_kva(host)==(void *)0x100000);
  assert(a01gpu_host_flush(host,0x1000,0x1000)==0 && flush_count==1);
  assert(a01gpu_host_flush(host,0x7000,0x1001)!=0 && flush_count==1);
  assert(a01gpu_host_flush(host,0,0)!=0 && flush_count==1);
  a01gpu_host_unpin(host);
  assert(!live_desc && !prepared && !live_maps);
}
'''
with tempfile.TemporaryDirectory() as d:
    source = Path(d) / 'host_pin.cpp'
    binary = Path(d) / 'host_pin'
    source.write_text(prefix + actual + suffix, encoding='utf-8')
    subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print('PASS: range rejection, failed pin cleanup, 32-bit physical limit and release')
