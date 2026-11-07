#!/usr/bin/env python3
"""Check disabled host transport's bounds and reply validation with mocks."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).parent / 'a01drm.c').read_text()
start = source.index('int\na01drm_import_host_disabled(')
end = source.index('\n}', start) + 2
code = source[start:end]
prefix = r'''
#include <stdint.h>
#include <errno.h>
#include <assert.h>
typedef int io_connect_t; typedef int kern_return_t;
#define IO_OBJECT_NULL 0
#define KERN_SUCCESS 0
static int scenario, calls;
static io_connect_t a01_connection(void) { return scenario==1 ? 0 : 1; }
static kern_return_t IOConnectCallScalarMethod(io_connect_t c,uint32_t selector,
 const uint64_t *in,uint32_t count,uint64_t *out,uint32_t *n) {
 assert(c==1 && selector==2 && count==2 && in[0]==0x4000 && in[1]==0x4000);
 ++calls; if(scenario==2) return 1;
 if(scenario==3) { *n=1; return 0; }
 out[0]=scenario==4; out[1]=scenario==5 ? 0 : 42; return 0;
}
'''
suffix = r'''
int main(void) {
 uint64_t out=99;
 assert(a01drm_import_host_disabled(0,0x4000,&out)==-EINVAL && out==0);
 assert(a01drm_import_host_disabled((void *)0x4001,0x4000,&out)==-EINVAL);
 assert(a01drm_import_host_disabled((void *)0x4000,0x4001,&out)==-EINVAL);
 assert(a01drm_import_host_disabled((void *)0xffffffffffffc000ULL,0x8000,&out)==-EINVAL);
 assert(a01drm_import_host_disabled((void *)0x4000,0x8004000,&out)==-EINVAL);
 assert(a01drm_import_host_disabled((void *)0x4000,0x4000,0)==-EINVAL);
 for(scenario=1;scenario<=5;++scenario) {
   out=99; assert(a01drm_import_host_disabled((void *)0x4000,0x4000,&out)<0 && out==0);
 }
 scenario=0; assert(a01drm_import_host_disabled((void *)0x4000,0x4000,&out)==0 && out==42);
 assert(calls==5);
}
'''
with tempfile.TemporaryDirectory() as d:
    c, exe = Path(d) / 'transport.c', Path(d) / 'transport'
    c.write_text(prefix + code + suffix, encoding='utf-8')
    subprocess.run(['gcc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(c), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print('PASS: invalid ranges, unavailable selector and invalid replies')
