/* Host test: run the loader's FDT scan on a real A01 Core DTB.
 *   gcc -DA01_HOST_TEST -o host_test host_test.c && ./host_test boot.dtb */
#define A01_HOST_TEST 1
/* the C runtime owns _start on Linux: rename the loader's linker symbols here */
#define _start shim_start
#define _image_end shim_image_end
#include <stdio.h>
#include <stdlib.h>
#include "a01core.c"
uint64_t a01_boot_args_pa;
char _start[64], _image_end[1];

int main(int argc, char **argv)
{
    if (argc < 2)
        return 2;
    FILE *f = fopen(argv[1], "rb");
    if (!f)
        return 2;
    static uint32_t buf[1 << 18];
    size_t n = fread(buf, 1, sizeof(buf), f);
    fclose(f);
    printf("read %zu bytes, scan=%d\n", n, fdt_scan((uintptr_t)buf));
    for (unsigned i = 0; i < nmem; i++)
        printf("MEM %#llx+%#llx\n", (unsigned long long)mem[i].base, (unsigned long long)mem[i].size);
    for (unsigned i = 0; i < nrsv; i++)
        printf("RSV %#llx+%#llx\n", (unsigned long long)rsv[i].base, (unsigned long long)rsv[i].size);
    printf("fb %#llx vram %#llx lcm '%s' initrd %#llx-%#llx\n", (unsigned long long)fb_fdt,
        (unsigned long long)vram_size, lcm_name, (unsigned long long)initrd_start,
        (unsigned long long)initrd_end);
    printf("conflict(0x60000000,1G)=%d conflict(0x4b000000,4K)=%d inside=%d\n",
        first_conflict(0x60000000, 0x40000000), first_conflict(0x4b000000, 4096),
        inside_dram(0x60000000, 0x40000000));
    return 0;
}
