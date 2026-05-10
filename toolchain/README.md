# Local Toolchain Placeholder

Put the RISC-V compiler package here if you want this repository to be
self-contained for builds and verification.

Expected layout:

```text
toolchain/
  xpack-riscv-none-elf-gcc/
    bin/
      riscv64-unknown-elf-gcc.exe
      riscv-none-elf-objcopy.exe
      riscv-none-elf-objdump.exe
```

The Makefile and PowerShell/Python build scripts first check this local path.
If it is not present, they fall back to `C:\riscv\xpack-riscv-none-elf-gcc\bin`
or explicit command-line overrides.

If you distribute the compiler binaries with the project, also keep the
corresponding license and source-availability information from the toolchain
distribution package.
