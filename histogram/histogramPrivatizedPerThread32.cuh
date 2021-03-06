/*
 *
 * histogramPrivatizedPerThread32.cuh
 *
 * Implementation of histogram that uses 8-bit privatized counters
 * and uses 32-bit increments to process them.
 *
 * Requires: SM 1.2, for shared atomics.
 *
 * Copyright (c) 2011-2012, Archaea Software, LLC.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions 
 * are met: 
 *
 * 1. Redistributions of source code must retain the above copyright 
 *    notice, this list of conditions and the following disclaimer. 
 * 2. Redistributions in binary form must reproduce the above copyright 
 *    notice, this list of conditions and the following disclaimer in 
 *    the documentation and/or other materials provided with the 
 *    distribution. 
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS 
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT 
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS 
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE 
 * COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER 
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN 
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
 * POSSIBILITY OF SUCH DAMAGE.
 *
 */

__global__ void
histogram1DPrivatizedPerThread32(
    unsigned int *pHist,
    const unsigned char *base, size_t N )
{
    extern __shared__ unsigned int privHist[];
    for ( int i = threadIdx.x;
              i < 64*blockDim.x;
              i += blockDim.x ) {
        privHist[i] = 0;
    }
    __syncthreads();
#define CACHE_IN_REGISTER 0
#if CACHE_IN_REGISTER
    int cacheIndex = 0;
    unsigned int cacheValue = 0;
#endif
    for ( int i = blockIdx.x*blockDim.x+threadIdx.x;
              i < N;
              i += blockDim.x*gridDim.x ) {
        unsigned char pixval = base[i];
        unsigned int increment = 1<<8*(pixval&3);
        int index = pixval>>2;
#if CACHE_IN_REGISTER
        if ( index != cacheIndex ) {
            privHist[cacheIndex*blockDim.x+threadIdx.x] = cacheValue;
            cacheIndex = index;
            cacheValue = privHist[index*blockDim.x+threadIdx.x];
        }
        cacheValue += increment;
#else
        privHist[index*blockDim.x+threadIdx.x] += increment;
#endif
    }
#if CACHE_IN_REGISTER
    privHist[cacheIndex*blockDim.x+threadIdx.x] = cacheValue;
#endif
    __syncthreads();
#if 1
    for ( int i = 0; i < 64; i++ ) {
        unsigned int sum;
        volatile unsigned int *histBase = &privHist[i*64+threadIdx.x];
        unsigned int myValue = histBase[0];
        privHist[i*64+threadIdx.x] = myValue & 0xff00ff;
        __syncthreads();
        myValue >>= 8;
        if ( threadIdx.x < 32 ) {
            histBase[0] += histBase[32];
            histBase[0] += histBase[16];
            histBase[0] += histBase[ 8];
            histBase[0] += histBase[ 4];
            histBase[0] += histBase[ 2];
            sum = histBase[0] + histBase[1];
            if ( threadIdx.x==0 && (sum&0xffff) ) atomicAdd( &pHist[i*4+0], sum&0xffff );
            sum >>= 16;
            if ( threadIdx.x==0 && sum ) atomicAdd( &pHist[i*4+2], sum );
        }

        histBase[0] = myValue & 0xff00ff;
        __syncthreads();
        if ( threadIdx.x < 32 ) {
            histBase[0] += histBase[32];
            histBase[0] += histBase[16];
            histBase[0] += histBase[ 8];
            histBase[0] += histBase[ 4];
            histBase[0] += histBase[ 2];
            sum = histBase[0] + histBase[1];
            if ( threadIdx.x==0 && (sum&0xffff) ) atomicAdd( &pHist[i*4+1], sum&0xffff );
            sum >>= 16;
            if ( threadIdx.x==0 && sum ) atomicAdd( &pHist[i*4+3], sum );
        }
        
    }
#if 0
    for ( int i = 0; i < 64; i++ ) {
        unsigned int count = privHist[i*64/*blockDim.x*/+threadIdx.x];
        atomicAdd( &pHist[i*4+0], count & 0xff );  count >>= 8;
        atomicAdd( &pHist[i*4+1], count & 0xff );  count >>= 8;
        atomicAdd( &pHist[i*4+2], count & 0xff );  count >>= 8;
        atomicAdd( &pHist[i*4+3], count );
    }
#endif
#else

    for ( int i = threadIdx.x;
              i < 64*blockDim.x;
              i += blockDim.x ) {
        int idx = i & 63;
        unsigned int count = privHist[i];
        atomicAdd( &pHist[idx*4+0], count & 0xff );  count >>= 8;
        atomicAdd( &pHist[idx*4+1], count & 0xff );  count >>= 8;
        atomicAdd( &pHist[idx*4+2], count & 0xff );  count >>= 8;
        atomicAdd( &pHist[idx*4+3], count );
    }
#endif
}

void
GPUhistogramPrivatizedPerThread32(
    float *ms,
    unsigned int *pHist,
    const unsigned char *dptrBase, size_t dPitch,
    int x, int y,
    int w, int h, 
    dim3 threads )
{
    cudaError_t status;
    cudaEvent_t start = 0, stop = 0;
    int numthreads = threads.x*threads.y;
    int numblocks = INTDIVIDE_CEILING( w*h, numthreads*255 );

    CUDART_CHECK( cudaEventCreate( &start, 0 ) );
    CUDART_CHECK( cudaEventCreate( &stop, 0 ) );

    CUDART_CHECK( cudaMemset( pHist, 0, 256*sizeof(unsigned int) ) );

    CUDART_CHECK( cudaEventRecord( start, 0 ) );
    histogram1DPrivatizedPerThread32<<<numblocks,numthreads,numthreads*256>>>( pHist, dptrBase, w*h );
    CUDART_CHECK( cudaEventRecord( stop, 0 ) );
    CUDART_CHECK( cudaDeviceSynchronize() );
    CUDART_CHECK( cudaEventElapsedTime( ms, start, stop ) );
Error:
    cudaEventDestroy( start );
    cudaEventDestroy( stop );
    return;
}
