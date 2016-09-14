/**
 *  @file alg4_gpu.cuh
 *  @brief Algorithm 4 in the GPU with borders
 *  @author Andre Maximo
 *  @date Nov, 2012
 *  @copyright The MIT License
 */

#ifndef ALG4_GPU_CUH
#define ALG4_GPU_CUH

#define MST == // measure step time: no: == ; yes: >=
#define LDG // uncomment to use __ldg
#if ORDER==1 || ORDER==2 || ORDER==5
#define REGS // uncomment to use registers
#endif

//== INCLUDES ==================================================================

#include "alg4v5v6_gpu.cuh"

//== NAMESPACES ================================================================

namespace gpufilter {

//== IMPLEMENTATION ============================================================

/**
 *  @ingroup gpu
 *  @brief Algorithm 4 step 1
 *
 *  This function computes the algorithm step 4.1 following:
 *
 *  \li In parallel for all \f$m\f$ and \f$n\f$, load block
 *  \f$B_{m,n}(X)\f$ then compute and store block perimeters
 *  \f$P_{m,n}(Y)\f$ and \f$E_{m,n}(Z)\f$.
 *
 *  @note The CUDA kernel functions (as this one) have many
 *  idiosyncrasies and should not be used lightly.
 *
 *  @note This follows the improved base-line implementation in [NehabMaximo:2016]
 *  @see [NehabEtAl:2011] cited in alg5() and [NehabMaximo:2016] cited in alg6()
 *  @param[out] g_pybar All \f$P_{m,n}(Y)\f$
 *  @param[out] g_ezhat All \f$E_{m,n}(Z)\f$
 *  @param[in] inv_width Image width inversed (1/w)
 *  @param[in] inv_height Image height inversed (1/h)
 *  @param[in] m_size The big M (number of row blocks)
 *  @tparam BORDER Flag to consider border input padding
 *  @tparam R Filter order
 */
template <bool BORDER, int R>
__global__ __launch_bounds__(WS*NWC, NBCW)
void alg4_step1( Matrix<float,R,WS> *g_pybar, 
                 Matrix<float,R,WS> *g_ezhat,
                 float inv_width, float inv_height,
                 int m_size ) {

    int tx = threadIdx.x, ty = threadIdx.y, m = blockIdx.x, n = blockIdx.y;

    __shared__ Matrix<float,WS,WS+1> block;
    if (BORDER) // read considering borders
        read_block<NWC>(block, m-c_border, n-c_border, inv_width, inv_height);
    else
        read_block<NWC>(block, m, n, inv_width, inv_height);
    __syncthreads();

#ifdef REGS
    float x[32]; // 32 regs
#endif

    if (ty==0) {

#ifdef REGS
#pragma unroll
        for (int i=0; i<32; ++i)
            x[i] = block[tx][i];
#endif

        Vector<float,R> p = zeros<float,R>();

#pragma unroll // calculate pybar, scan left -> right
        for (int j=0; j<WS; ++j)
#ifdef REGS
            x[j] = fwdI(p, x[j], c_weights);
#else
            block[tx][j] = fwdI(p, block[tx][j], c_weights);
#endif

        g_pybar[n*(m_size+1)+m+1].set_col(tx, p);
        
        Vector<float,R> e = zeros<float,R>();

#pragma unroll // calculate ezhat, scan right -> left
        for (int j=WS-1; j>=0; --j)
#ifdef REGS
            revI(x[j], e, c_weights);
#else
            revI(block[tx][j], e, c_weights);
#endif

        g_ezhat[n*(m_size+1)+m].set_col(tx, e);

    }

}

/**
 *  @ingroup gpu
 *  @brief Algorithm 4 step 3 or 5
 *
 *  This function computes the algorithm step 4.3 or 4.5
 *  (corresponding to the step 4.4 or 4.7 in [NehabEtAl:2011])
 *  following:
 *
 *  \li In parallel for all \f$m\f$ and \f$n\f$, load block
 *  \f$B_{m,n}(X)\f$ and column block feedbacks \f$P_{m-1,n}(Y)\f$ and
 *  \f$E_{m+1,n}(Z)\f$, compute and store B_{m,n}(Z) and then compute
 *  and store block perimeters \f$P^T_{m,n}(U)\f$ and
 *  \f$E^T_{m,n}(V)\f$.
 *
 *  \li In parallel for all \f$m\f$ and \f$n\f$, load block
 *  \f$B_{m,n}(Z)\f$ and row block feedbacks \f$P^T_{m,n-1}(U)\f$ and
 *  \f$E^T_{m,n+1}(V)\f$.  Compute and store B_{m,n}(V).
 *
 *  @note The CUDA kernel functions (as this one) have many
 *  idiosyncrasies and should not be used lightly.
 *
 *  @note This follows the improved base-line implementation in [NehabMaximo:2016]
 *  @see [NehabEtAl:2011] cited in alg5() and [NehabMaximo:2016] cited in alg6()
 *  @param[out] g_transp_out The output transposed 2D image
 *  @param[in] g_rows_py All \f$P_{m,n}(Y)\f$ or \f$P^T_{m,n}(U)\f$ 
 *  @param[in] g_rows_ez All \f$E_{m,n}(Z)\f$ or \f$E^T_{m,n}(V)\f$ 
 *  @param[in] g_cols_py All \f$P^T_{m,n}(U)\f$ (for 4.3 fusion)
 *  @param[in] g_cols_ez All \f$E^T_{m,n}(V)\f$ (for 4.3 fusion)
 *  @param[in] inv_width Image width inversed (1/w)
 *  @param[in] inv_height Image height inversed (1/h)
 *  @param[in] m_size The big M (number of row blocks)
 *  @param[in] n_size The big N (number of column blocks)
 *  @param[in] out_stride Image output stride for memory width alignment
 *  @tparam FUSION Flag for 4.3 fusion to compute feedbacks in other direction
 *  @tparam BORDER Flag to consider border input padding
 *  @tparam R Filter order
 */
template <bool FUSION, bool BORDER, int R>
__global__ __launch_bounds__(WS*NWW, NBCW)
void alg4_step3v5( float *g_transp_out,
                   const Matrix<float,R,WS> *g_rows_py,
                   const Matrix<float,R,WS> *g_rows_ez,
                   Matrix<float,R,WS> *g_cols_py,
                   Matrix<float,R,WS> *g_cols_ez,
                   float inv_width, float inv_height,
                   int m_size, int n_size,
                   int out_stride ) {

    int tx = threadIdx.x, ty = threadIdx.y, m = blockIdx.x, n = blockIdx.y;

    __shared__ Matrix<float,WS,WS+1> block;
    if (BORDER) // read considering borders
        read_block<NWW>(block, m-c_border, n-c_border, inv_width, inv_height);
    else
        read_block<NWW>(block, m, n, inv_width, inv_height);
    __syncthreads();

#ifdef REGS
    float x[32];
#endif

    if (ty==0) {

#ifdef REGS
#pragma unroll
        for (int i=0; i<32; ++i)
            x[i] = block[tx][i];
#endif

        Vector<float,R> p, e;

#ifdef LDG
#pragma unroll
        for (int r=0; r<R; ++r)
            p[r] = __ldg((const float *)&g_rows_py[n*(m_size+1)+m][r][tx]);
#else
        p = ((Matrix<float,R,WS>*)&g_rows_py[n*(m_size+1)+m][0][tx])->col(0);
#endif

#pragma unroll // calculate block, scan left -> right
        for (int j=0; j<WS; ++j)
#ifdef REGS
            x[j] = fwdI(p, x[j], c_weights);
#else
            block[tx][j] = fwdI(p, block[tx][j], c_weights);
#endif

#ifdef LDG
#pragma unroll
        for (int r=0; r<R; ++r)
            e[r] = __ldg((const float *)&g_rows_ez[n*(m_size+1)+m+1][r][tx]);
#else
        e = ((Matrix<float,R,WS>*)&g_rows_ez[n*(m_size+1)+m+1][0][tx])->col(0);
#endif

#pragma unroll // calculate block, scan right -> left
        for (int j=WS-1; j>=0; --j)
#ifdef REGS
            x[j] = revI(x[j], e, c_weights);
#else
            block[tx][j] = revI(block[tx][j], e, c_weights);
#endif

        if (BORDER) {
            if ((m >= c_border) && (m < m_size-c_border) && (n >= c_border) && (n < n_size-c_border)) {
                g_transp_out += (m-c_border)*WS*out_stride + (n-c_border)*WS + tx;
#pragma unroll // write block inside valid transpose image
                for (int i=0; i<WS; ++i, g_transp_out += out_stride) {
#ifdef REGS
                    *g_transp_out = x[i];
#else
                    *g_transp_out = block[tx][i];
#endif
                }
            }
        } else {
            g_transp_out += m*WS*out_stride + n*WS + tx;
#pragma unroll // write block inside valid transpose image
            for (int i=0; i<WS; ++i, g_transp_out += out_stride) {
#ifdef REGS
                *g_transp_out = x[i];
#else
                *g_transp_out = block[tx][i];
#endif
            }
        }

        if (FUSION) {

#ifdef REGS
#pragma unroll // transpose regs part-1
            for (int i=0; i<32; ++i)
                block[tx][i] = x[i];
#pragma unroll // transpose regs part-2
            for (int i=0; i<32; ++i)
                x[i] = block[i][tx];
#endif

            Matrix<float,R,WS>
                &pybar = (Matrix<float,R,WS>&)g_cols_py[m*(n_size+1)+n+1][0][tx],
                &ezhat = (Matrix<float,R,WS>&)g_cols_ez[m*(n_size+1)+n][0][tx];

            p = zeros<float,R>();

#pragma unroll // calculate pybar cols, scan left -> right
            for (int j=0; j<WS; ++j)
#ifdef REGS
                x[j] = fwdI(p, x[j], c_weights);
#else
                block[j][tx] = fwdI(p, block[j][tx], c_weights);
#endif

            pybar.set_col(0, p); // store pybar cols

            e = zeros<float,R>();

#pragma unroll // calculate ezhat cols, scan right -> left
            for (int j=WS-1; j>=0; --j)
#ifdef REGS
                revI(x[j], e, c_weights);
#else
                revI(block[j][tx], e, c_weights);
#endif

            ezhat.set_col(0, e); // store ezhat cols

        }

    }

}

/**
 *  @ingroup api_gpu
 *  @brief Compute algorithm 4 in the GPU
 *
 *  @see [NehabEtAl:2011] cited in alg5() and [NehabMaximo:2016] cited in alg6()
 *  @param[in,out] h_img The in(out)put 2D image to filter in host memory
 *  @param[in] width Image width
 *  @param[in] height Image height
 *  @param[in] runtimes Number of run times (1 for debug and 1000 for performance measurements)
 *  @param[in] w Filter weights (feedforward and feedforward coefficients)
 *  @param[in] border Number of border blocks (32x32) outside image
 *  @param[in] btype Border type (either zero, clamp, repeat or reflect)
 *  @tparam BORDER Flag to consider border input padding
 *  @tparam R Filter order
 */
template <bool BORDER, int R>
__host__
void alg4_gpu( float *h_img,
               int width, int height, int runtimes,
               const Vector<float, R+1> &w,
               int border=0,
               BorderType border_type=CLAMP_TO_ZERO ) {

    const int B = WS;

    // pre-compute basic alg4 matrices
    Matrix<float,R,R> Ir = identity<float,R,R>();
    Matrix<float,B,R> Zbr = zeros<float,B,R>();
    Matrix<float,R,B> Zrb = zeros<float,R,B>();
    Matrix<float,B,B> Ib = identity<float,B,B>();

    Matrix<float,R,B> AFP_T = fwd(Ir, Zrb, w),
                      ARE_T = rev(Zrb, Ir, w);
    Matrix<float,B,B> AFB_T = fwd(Zbr, Ib, w),
                      ARB_T = rev(Ib, Zbr, w);

    Matrix<float,R,R> AbF_T = tail<R>(AFP_T),
                      AbR_T = head<R>(ARE_T),
                      HARB_AFP_T = AFP_T*head<R>(ARB_T);

    int m_size = (width+WS-1)/WS, n_size = (height+WS-1)/WS;

    if (BORDER) {
        int border_left, border_top, border_right, border_bottom;
        calc_borders(&border_left, &border_top, &border_right, &border_bottom, 
                     width, height, border);
        int ewidth = width+border_left+border_right,
            eheight = height+border_top+border_bottom;

        m_size = (ewidth+WS-1)/WS;
        n_size = (eheight+WS-1)/WS;

        copy_to_symbol(c_border, border);
    }

    // upload to the GPU
    copy_to_symbol(c_weights, w);

    copy_to_symbol(c_AbF_T, AbF_T);
    copy_to_symbol(c_AbR_T, AbR_T);
    copy_to_symbol(c_HARB_AFP_T, HARB_AFP_T);

    float inv_width = 1.f/width, inv_height = 1.f/height;

    cudaArray *a_in;
    size_t offset;
    cudaChannelFormatDesc ccd = cudaCreateChannelDesc<float>();
    cudaMallocArray(&a_in, &ccd, width, height);
    cudaMemcpyToArray(a_in, 0, 0, h_img, width*height*sizeof(float),
                      cudaMemcpyHostToDevice);

    t_in.normalized = true;
    t_in.filterMode = cudaFilterModePoint;
    t_in.addressMode[0] = t_in.addressMode[1] = cudaAddressModeBorder;

    if (BORDER) {
        switch(border_type) {
        case CLAMP_TO_ZERO:
            t_in.addressMode[0] = t_in.addressMode[1] = cudaAddressModeBorder;
            break;
        case CLAMP_TO_EDGE:
            t_in.addressMode[0] = t_in.addressMode[1] = cudaAddressModeClamp;
            break;
        case REPEAT:
            t_in.addressMode[0] = t_in.addressMode[1] = cudaAddressModeWrap;
            break;
        case REFLECT:
            t_in.addressMode[0] = t_in.addressMode[1] = cudaAddressModeMirror;
            break;
        }
    }

    int stride_img = width+WS, stride_transp_img = width+WS;
    if (BORDER) stride_img = stride_transp_img = width+WS*border+WS;

    dvector<float> d_img(height*stride_img), d_transp_img(width*stride_transp_img);

    // +1 padding is important even in zero-border to avoid if's in kernels
    dvector< Matrix<float,R,B> >
        d_rows_pybar((m_size+1)*n_size), d_rows_ezhat((m_size+1)*n_size),
        d_cols_pybar((n_size+1)*m_size), d_cols_ezhat((n_size+1)*m_size);
    d_rows_pybar.fillzero();
    d_rows_ezhat.fillzero();
    d_cols_pybar.fillzero();
    d_cols_ezhat.fillzero();

    cudaFuncSetCacheConfig(alg4_step1<BORDER,R>, cudaFuncCachePreferShared);
    cudaFuncSetCacheConfig(alg4_step3v5<true,BORDER,R>, cudaFuncCachePreferShared);
    cudaFuncSetCacheConfig(alg4_step3v5<false,BORDER,R>, cudaFuncCachePreferShared);

    if (R == 1)
        cudaFuncSetCacheConfig(alg4v5v6_step2v4<R>, cudaFuncCachePreferL1);
    else if (R == 2)
        cudaFuncSetCacheConfig(alg4v5v6_step2v4<R>, cudaFuncCachePreferEqual);
    else if (R >= 3)
        cudaFuncSetCacheConfig(alg4v5v6_step2v4<R>, cudaFuncCachePreferShared);

    double te[5] = {0, 0, 0, 0, 0}; // time elapsed for the five steps
    base_timer *timer[5];
    for (int i = 0; i < 5; ++i)
        timer[i] = new gpu_timer(0, "", false);

    base_timer &timer_total = timers.gpu_add("alg4_gpu", width*height, "iP");

    for(int r = 0; r < runtimes; ++r) {

        if (runtimes MST 1) { timer[0]->start(); }

        cudaBindTextureToArray(t_in, a_in);

        alg4_step1<BORDER><<< dim3(m_size, n_size), dim3(WS, NWC) >>>
            ( &d_rows_pybar, &d_rows_ezhat, inv_width, inv_height, m_size );

        if (runtimes MST 1) { timer[0]->stop(); te[0] += timer[0]->elapsed(); timer[1]->start(); }

        alg4v5v6_step2v4<<< dim3(1, n_size), dim3(WS, NWA) >>>
            ( &d_rows_pybar, &d_rows_ezhat, m_size );

        if (runtimes MST 1) { timer[1]->stop(); te[1] += timer[1]->elapsed(); timer[2]->start(); }

        alg4_step3v5<true, BORDER><<< dim3(m_size, n_size), dim3(WS, NWW) >>>
            ( d_transp_img, &d_rows_pybar, &d_rows_ezhat, &d_cols_pybar, &d_cols_ezhat,
              inv_width, inv_height, m_size, n_size, stride_transp_img );
    
        cudaUnbindTexture(t_in);
        cudaBindTexture2D(&offset, t_in, d_transp_img, height, width, stride_transp_img*sizeof(float));

        if (runtimes MST 1) { timer[2]->stop(); te[2] += timer[2]->elapsed(); timer[3]->start(); }

        alg4v5v6_step2v4<<< dim3(1, m_size), dim3(WS, NWA) >>>
            ( &d_cols_pybar, &d_cols_ezhat, n_size );

        if (runtimes MST 1) { timer[3]->stop(); te[3] += timer[3]->elapsed(); timer[4]->start(); }

        alg4_step3v5<false, BORDER><<< dim3(n_size, m_size), dim3(WS, NWW) >>>
            ( d_img, &d_cols_pybar, &d_cols_ezhat, &d_rows_pybar, &d_cols_ezhat,
              inv_height, inv_width, n_size, m_size, stride_img );

        cudaUnbindTexture(t_in);

        if (runtimes MST 1) { timer[4]->stop(); te[4] += timer[4]->elapsed(); }

    }

    timer_total.stop();

    if (runtimes > 1) {

        if (runtimes MST 1) {
            for (int i = 0; i < 5; ++i)
                std::cout << std::fixed << " " << te[i]/(double)runtimes << std::flush;
        } else {
            std::cout << std::fixed << (timer_total.data_size()*runtimes)/(double)(timer_total.elapsed()*1024*1024) << std::flush;
        }

    } else {

        timers.gpu_add("step 1", timer[0]);
        timers.gpu_add("step 2", timer[1]);
        timers.gpu_add("step 3", timer[2]);
        timers.gpu_add("step 4", timer[3]);
        timers.gpu_add("step 5", timer[4]);
        timers.flush();

    }

    cudaMemcpy2D(h_img, width*sizeof(float), d_img, stride_img*sizeof(float), width*sizeof(float), height, cudaMemcpyDeviceToHost);

}

//==============================================================================
} // namespace gpufilter
//==============================================================================
#endif // ALG4_GPU_CUH
//==============================================================================
