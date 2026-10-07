// vectoradd.cu — minimal CUDA bandwidth/compute probe for the MX130 (sm_50).
// Part of the MX130 GPU experiment: docs/experiments/mx130/
//
// NOTE (2026-10, pve3): CUDA 12.8 headers clash with glibc 2.41's
// `noexcept`-decorated math declarations. Applied patches (backups kept as
// *.pre-mx130) to $CUDA/targets/x86_64-linux/include/crt/math_functions.h
// and math_functions.hpp: sinpif/cospif/tanpif/sinpi/cospi/tanpi got
// `noexcept (true)` added. Recompile after a toolkit reinstall if needed.
//
// Build:  nvcc -O2 -arch=sm_50 -o vectoradd vectoradd.cu
// Run:    LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64 ./vectoradd
#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>

#define CHECK(x) do { cudaError_t e = (x); if (e != cudaSuccess) { \
    printf("CUDA error: %s (line %d)\n", cudaGetErrorString(e), __LINE__); exit(1); } } while (0)

__global__ void fill(float *p, float v, size_t n) {
    size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x;
    size_t stride = (size_t)gridDim.x * blockDim.x;
    for (; i < n; i += stride)
        p[i] = v;
}

__global__ void vadd(const float *a, const float *b, float *c, size_t n) {
    size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x;
    size_t stride = (size_t)gridDim.x * blockDim.x;
    for (; i < n; i += stride)
        c[i] = a[i] + b[i];
}

int main(void) {
    int dev = 0, rt = 0;
    cudaDeviceProp p;
    CHECK(cudaGetDevice(&dev));
    CHECK(cudaGetDeviceProperties(&p, dev));
    CHECK(cudaRuntimeGetVersion(&rt));
    printf("Device:        %s\n", p.name);
    printf("Compute cap:   %d.%d   (CUDA runtime %d.%d)\n", p.major, p.minor, rt / 1000, (rt % 1000) / 10);
    printf("SMs:           %d\n", p.multiProcessorCount);
    printf("Clock:         %.0f MHz\n", p.clockRate / 1000.0);
    printf("VRAM:          %zu MiB\n", (size_t)(p.totalGlobalMem >> 20));

    const size_t n = (size_t)1 << 26;            // 64 Mi float = 256 MiB per array
    const size_t bytes = n * sizeof(float);
    printf("\nVector add:    %zu elements (%.0f MiB per array, 3 arrays)\n", n, bytes / 1048576.0);

    float *a, *b, *c;
    CHECK(cudaMalloc(&a, bytes));
    CHECK(cudaMalloc(&b, bytes));
    CHECK(cudaMalloc(&c, bytes));

    const int threads = 256, blocks = 256;
    fill<<<blocks, threads>>>(a, 1.0f, n);
    fill<<<blocks, threads>>>(b, 2.0f, n);
    CHECK(cudaDeviceSynchronize());

    cudaEvent_t t0, t1;
    CHECK(cudaEventCreate(&t0));
    CHECK(cudaEventCreate(&t1));

    const int reps = 10;
    CHECK(cudaEventRecord(t0));
    for (int r = 0; r < reps; r++)
        vadd<<<blocks, threads>>>(a, b, c, n);
    CHECK(cudaEventRecord(t1));
    CHECK(cudaEventSynchronize(t1));

    float ms = 0.0f;
    CHECK(cudaEventElapsedTime(&ms, t0, t1));
    const double flops = (double)reps * (double)n;            // 1 FLOP per element-add
    const double moved = (double)reps * 3.0 * (double)bytes;  // 2 reads + 1 write
    printf("Result:        %.2f ms per rep\n", ms / reps);
    printf("Throughput:    %.1f GFLOP/s (bandwidth-bound; 1 add per 12 bytes)\n", flops / (ms * 1e6));
    printf("Memory:        %.1f GB/s achieved\n", moved / (ms * 1e6));

    float first = 0.0f;
    CHECK(cudaMemcpy(&first, c, sizeof(float), cudaMemcpyDeviceToHost));
    printf("Verify:        c[0] = %.1f (expected 3.0)%s\n", first, (first == 3.0f) ? " OK" : " MISMATCH!");

    cudaFree(a); cudaFree(b); cudaFree(c);
    return 0;
}
