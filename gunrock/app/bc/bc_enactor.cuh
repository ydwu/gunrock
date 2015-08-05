// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * bc_enactor.cuh
 *
 * @brief BC Problem Enactor
 */

#pragma once

#include <gunrock/util/multithreading.cuh>
#include <gunrock/util/multithread_utils.cuh>
#include <gunrock/util/kernel_runtime_stats.cuh>
#include <gunrock/util/test_utils.cuh>

#include <gunrock/oprtr/advance/kernel.cuh>
#include <gunrock/oprtr/advance/kernel_policy.cuh>
#include <gunrock/oprtr/filter/kernel.cuh>
#include <gunrock/oprtr/filter/kernel_policy.cuh>

#include <gunrock/app/enactor_base.cuh>
#include <gunrock/app/bc/bc_problem.cuh>
#include <gunrock/app/bc/bc_functor.cuh>


namespace gunrock {
namespace app {
namespace bc {

template <typename Problem, bool _INSTRUMENT, bool _DEBUG, bool _SIZE_CHECK> class Enactor;

/*
 * @brief Expand incoming function.
 *
 * @tparam VertexId
 * @tparam SizeT
 * @tparam Value
 * @tparam NUM_VERTEX_ASSOCIATES
 * @tparam NUM_VALUE__ASSOCIATES
 *
 * @param[in] num_elements
 * @param[in] keys_in
 * @param[in] keys_out
 * @param[in] array_size
 * @param[in] array
 */
template <
    typename VertexId,
    typename SizeT,
    typename Value,
    int      NUM_VERTEX_ASSOCIATES,
    int      NUM_VALUE__ASSOCIATES>
__global__ void Expand_Incoming_Forward (
    const SizeT            num_elements,
    const VertexId* const  keys_in,
          VertexId*        keys_out,
    const size_t           array_size,
          char*            array)
{
    extern __shared__ char s_array[];
    const SizeT STRIDE = gridDim.x * blockDim.x;
    VertexId    t;
    size_t      offset                = 0;
    VertexId** s_vertex_associate_in  = (VertexId**)&(s_array[offset]);
    offset+=sizeof(VertexId*) * NUM_VERTEX_ASSOCIATES;
    Value**    s_value__associate_in  = (Value**   )&(s_array[offset]);
    offset+=sizeof(Value*   ) * NUM_VALUE__ASSOCIATES;
    VertexId** s_vertex_associate_org = (VertexId**)&(s_array[offset]);
    offset+=sizeof(VertexId*) * NUM_VERTEX_ASSOCIATES;
    Value**    s_value__associate_org = (Value**   )&(s_array[offset]);
    SizeT x = threadIdx.x;
    while (x < array_size)
    {
        s_array[x]=array[x];
        x+=blockDim.x;
    }
    __syncthreads();

    x = blockIdx.x * blockDim.x + threadIdx.x;

    while (x<num_elements)
    {
        VertexId key=keys_in[x];

        if (atomicCAS(s_vertex_associate_org[1]+key, -2, s_vertex_associate_in[1][x])==-2)
        {
            s_vertex_associate_org[0][key]=s_vertex_associate_in[0][x];
            t=-1;
        } else {
            t=atomicCAS(s_vertex_associate_org[0]+key, -1, s_vertex_associate_in[0][x]);
            if (s_vertex_associate_org[0][key]!=s_vertex_associate_in[0][x])
            {
                keys_out[x]=-1;
                x+=STRIDE;
                continue;
            }
        }
        if (t==-1) keys_out[x]=key; else keys_out[x]=-1;
        atomicAdd(s_value__associate_org[0]+key, s_value__associate_in[0][x]);
        x+=STRIDE;
    }
}

/*
 * @brief Expand incoming function.
 *
 * @tparam VertexId
 * @tparam SizeT
 * @tparam Value
 * @tparam NUM_VERTEX_ASSOCIATES
 * @tparam NUM_VALUE__ASSOCIATES
 *
 * @param[in] num_elements
 * @param[in] keys_in
 * @param[in] keys_out
 * @param[in] array_size
 * @param[in] array
 */
template <
    typename VertexId,
    typename SizeT,
    typename Value,
    int      NUM_VERTEX_ASSOCIATES,
    int      NUM_VALUE__ASSOCIATES>
__global__ void Expand_Incoming_Backward (
    const SizeT            num_elements,
    const VertexId* const  keys_in,
          VertexId*        keys_out,
    const size_t           array_size,
          char*            array)
{
    extern __shared__ char s_array[];
    const SizeT STRIDE = gridDim.x * blockDim.x;
    size_t      offset                = 0;
    offset+=sizeof(VertexId*) * NUM_VERTEX_ASSOCIATES;
    Value**    s_value__associate_in  = (Value**   )&(s_array[offset]);
    offset+=sizeof(Value*   ) * NUM_VALUE__ASSOCIATES;
    offset+=sizeof(VertexId*) * NUM_VERTEX_ASSOCIATES;
    Value**    s_value__associate_org = (Value**   )&(s_array[offset]);
    SizeT x = threadIdx.x;
    if (x < array_size)
    {
        s_array[x]=array[x];
        x+=blockDim.x;
    }
    __syncthreads();

    x = blockIdx.x * blockDim.x + threadIdx.x;

    while (x<num_elements)
    {
        VertexId key=keys_in[x];
        keys_out[x]=key;
        s_value__associate_org[0][key]=s_value__associate_in[0][x];
        s_value__associate_org[1][key]=s_value__associate_in[1][x];
        x+=STRIDE;
    }
}

/*
 * @brief Iteration structure derived from IterationBase.
 *
 * @tparam AdvanceKernelPolicy Kernel policy for advance operator.
 * @tparam FilterKernelPolicy Kernel policy for filter operator.
 * @tparam Enactor Enactor we process on.
 */
template <
    typename AdvanceKernelPolicy,
    typename FilterKernelPolicy,
    typename Enactor>
struct Forward_Iteration : public IterationBase <
    AdvanceKernelPolicy, FilterKernelPolicy, Enactor,
    false, //HAS_SUBQ
    true , //HAS_FULLQ
    false, //BACKWARD
    true , //FORWARD
    true > //UPDATE_PREDECESSORS
{
public:
    typedef typename Enactor::SizeT      SizeT     ;
    typedef typename Enactor::Value      Value     ;
    typedef typename Enactor::VertexId   VertexId  ;
    typedef typename Enactor::Problem    Problem   ;
    typedef typename Problem::DataSlice  DataSlice ;
    typedef GraphSlice<SizeT, VertexId, Value> GraphSlice;
    typedef ForwardFunctor<
            VertexId,
            SizeT,
            Value,
            Problem> ForwardFunctor;

    /*
     * @brief FullQueue_Gather function.
     *
     * @param[in] thread_num Number of threads.
     * @param[in] peer_ Peer GPU index.
     * @param[in] frontier_queue Pointer to the frontier queue.
     * @param[in] partitioned_scanned_edges Pointer to the scanned edges.
     * @param[in] frontier_attribute Pointer to the frontier attribute.
     * @param[in] enactor_stats Pointer to the enactor statistics.
     * @param[in] data_slice Pointer to the data slice we process on.
     * @param[in] d_data_slice Pointer to the data slice on the device.
     * @param[in] graph_slice Pointer to the graph slice we process on.
     * @param[in] work_progress Pointer to the work progress class.
     * @param[in] context CudaContext for ModernGPU API.
     * @param[in] stream CUDA stream.
     */
    static void FullQueue_Gather(
        int                            thread_num,
        int                            peer_,
        util::DoubleBuffer<SizeT, VertexId, Value>
                                      *frontier_queue,
        util::Array1D<SizeT, SizeT>   *scanned_edges,
        FrontierAttribute<SizeT>      *frontier_attribute,
        EnactorStats                  *enactor_stats,
        DataSlice                     *data_slice,
        DataSlice                     *d_data_slice,
        GraphSlice                    *graph_slice,
        util::CtaWorkProgressLifetime *work_progress,
        ContextPtr                     context,
        cudaStream_t                   stream)
    {
        if (enactor_stats->iteration <= 0) return;

        SizeT cur_offset = data_slice->forward_queue_offsets[peer_].back();
        bool oversized = false;
        if (enactor_stats->retval =
            Check_Size<Enactor::SIZE_CHECK, SizeT, VertexId> ("forward_output", cur_offset + frontier_attribute->queue_length, &data_slice->forward_output[peer_], oversized, thread_num, enactor_stats->iteration, peer_)) return;
        util::MemsetCopyVectorKernel<<<128, 128, 0, stream>>>(
            data_slice ->forward_output[peer_].GetPointer(util::DEVICE) + cur_offset,
            frontier_queue->keys[frontier_attribute->selector].GetPointer(util::DEVICE),
            frontier_attribute->queue_length);
        data_slice->forward_queue_offsets[peer_].push_back(frontier_attribute->queue_length+cur_offset);
    }

    /*
     * @brief FullQueue_Core function.
     *
     * @param[in] thread_num Number of threads.
     * @param[in] peer_ Peer GPU index.
     * @param[in] frontier_queue Pointer to the frontier queue.
     * @param[in] partitioned_scanned_edges Pointer to the scanned edges.
     * @param[in] frontier_attribute Pointer to the frontier attribute.
     * @param[in] enactor_stats Pointer to the enactor statistics.
     * @param[in] data_slice Pointer to the data slice we process on.
     * @param[in] d_data_slice Pointer to the data slice on the device.
     * @param[in] graph_slice Pointer to the graph slice we process on.
     * @param[in] work_progress Pointer to the work progress class.
     * @param[in] context CudaContext for ModernGPU API.
     * @param[in] stream CUDA stream.
     */
    static void FullQueue_Core(
        int                            thread_num,
        int                            peer_,
        util::DoubleBuffer<SizeT, VertexId, Value>
                                      *frontier_queue,
        util::Array1D<SizeT, SizeT>   *scanned_edges,
        FrontierAttribute<SizeT>      *frontier_attribute,
        EnactorStats                  *enactor_stats,
        DataSlice                     *data_slice,
        DataSlice                     *d_data_slice,
        GraphSlice                    *graph_slice,
        util::CtaWorkProgressLifetime *work_progress,
        ContextPtr                     context,
        cudaStream_t                   stream)
    {
        if (Enactor::DEBUG) util::cpu_mt::PrintMessage("Advance begin",thread_num, enactor_stats->iteration);

        frontier_attribute->queue_reset = true;
        // Edge Map
        gunrock::oprtr::advance::LaunchKernel<AdvanceKernelPolicy, Problem, ForwardFunctor>(
            enactor_stats[0],
            frontier_attribute[0],
            d_data_slice,
            (VertexId*)NULL,
            (bool*)    NULL,
            (bool*)    NULL,
            scanned_edges->GetPointer(util::DEVICE),
            frontier_queue->keys[frontier_attribute->selector  ].GetPointer(util::DEVICE),// d_in_queue
            frontier_queue->keys[frontier_attribute->selector^1].GetPointer(util::DEVICE),// d_out_queue
            (VertexId*)NULL,
            (VertexId*)   NULL,
            graph_slice->row_offsets   .GetPointer(util::DEVICE),
            graph_slice->column_indices.GetPointer(util::DEVICE),
            (SizeT*)   NULL,
            (VertexId*)NULL,
            graph_slice->nodes, //graph_slice->frontier_elements[frontier_attribute.selector],  // max_in_queue
            graph_slice->edges, //graph_slice->frontier_elements[frontier_attribute.selector^1],// max_out_queue
            work_progress[0],
            context[0],
            stream,
            gunrock::oprtr::advance::V2V,
            false,
            false,
            false);

        frontier_attribute->queue_reset = false;
        frontier_attribute->queue_index++;
        frontier_attribute->selector ^= 1;
        enactor_stats      -> Accumulate(
            work_progress  -> GetQueueLengthPointer<unsigned int,SizeT>(frontier_attribute->queue_index), stream);

        if (Enactor::DEBUG) util::cpu_mt::PrintMessage("Advance end", thread_num, enactor_stats->iteration);

        // Filter
        gunrock::oprtr::filter::Kernel<FilterKernelPolicy, Problem, ForwardFunctor>
            <<<enactor_stats->filter_grid_size, FilterKernelPolicy::THREADS, 0, stream>>>(
            enactor_stats->iteration+1,
            frontier_attribute->queue_reset,
            frontier_attribute->queue_index,
            frontier_attribute->queue_length,
            frontier_queue->keys[frontier_attribute->selector  ].GetPointer(util::DEVICE),// d_in_queue
            NULL,
            frontier_queue->keys[frontier_attribute->selector^1].GetPointer(util::DEVICE),// d_out_queue
            d_data_slice,
            NULL,
            work_progress[0],
            frontier_queue->keys[frontier_attribute->selector  ].GetSize(),// max_in_queue
            frontier_queue->keys[frontier_attribute->selector^1].GetSize(),// max_out_queue
            enactor_stats->filter_kernel_stats);

        if (Enactor::DEBUG && (enactor_stats->retval = util::GRError("filter_forward::Kernel failed", __FILE__, __LINE__))) return;
        if (Enactor::DEBUG) util::cpu_mt::PrintMessage("Filter end.", thread_num, enactor_stats->iteration);
        frontier_attribute->queue_index++;
        frontier_attribute->selector ^= 1;
        if (enactor_stats->retval = work_progress->GetQueueLength(frontier_attribute->queue_index, frontier_attribute->queue_length,false,stream,true)) return;
        if (enactor_stats->retval = util::GRError(cudaStreamSynchronize(stream), "cudaStreamSynchronize failed", __FILE__, __LINE__)) return;
    }

    /*
     * @brief Expand incoming function.
     *
     * @tparam NUM_VERTEX_ASSOCIATES
     * @tparam NUM_VALUE__ASSOCIATES
     *
     * @param[in] grid_size
     * @param[in] block_size
     * @param[in] shared_size
     * @param[in] stream
     * @param[in] num_elements
     * @param[in] keys_in
     * @param[in] keys_out
     * @param[in] array_size
     * @param[in] array
     * @param[in] data_slice
     */
    template <int NUM_VERTEX_ASSOCIATES, int NUM_VALUE__ASSOCIATES>
    static void Expand_Incoming(
              int             grid_size,
              int             block_size,
              size_t          shared_size,
              cudaStream_t    stream,
              SizeT           &num_elements,
        const VertexId* const keys_in,
        util::Array1D<SizeT, VertexId>*       keys_out,
        const size_t          array_size,
              char*           array,
              DataSlice*      data_slice)
    {
        bool over_sized = false;

        Check_Size<Enactor::SIZE_CHECK, SizeT, VertexId>(
            "queue1", num_elements, keys_out, over_sized, -1, -1, -1);
        Expand_Incoming_Forward
            <VertexId, SizeT, Value, NUM_VERTEX_ASSOCIATES, NUM_VALUE__ASSOCIATES>
            <<<grid_size, block_size, shared_size, stream>>> (
            num_elements,
            keys_in,
            keys_out->GetPointer(util::DEVICE),
            array_size,
            array);
    }

    /*
     * @brief Compute output queue length function.
     *
     * @param[in] frontier_attribute Pointer to the frontier attribute.
     * @param[in] d_offsets Pointer to the offsets.
     * @param[in] d_indices Pointer to the indices.
     * @param[in] d_in_key_queue Pointer to the input mapping queue.
     * @param[in] partitioned_scanned_edges Pointer to the scanned edges.
     * @param[in] max_in Maximum input queue size.
     * @param[in] max_out Maximum output queue size.
     * @param[in] context CudaContext for ModernGPU API.
     * @param[in] stream CUDA stream.
     * @param[in] ADVANCE_TYPE Advance kernel mode.
     * @param[in] express Whether or not enable express mode.
     *
     * \return cudaError_t object Indicates the success of all CUDA calls.
     */
    static cudaError_t Compute_OutputLength(
        FrontierAttribute<SizeT>       *frontier_attribute,
        SizeT                          *d_offsets,
        VertexId                       *d_indices,
        SizeT                          *d_inv_offsets,
        VertexId                       *d_inv_indices,
        VertexId                       *d_in_key_queue,
        util::Array1D<SizeT, SizeT>    *partitioned_scanned_edges,
        SizeT                          max_in,
        SizeT                          max_out,
        CudaContext                    &context,
        cudaStream_t                   stream,
        gunrock::oprtr::advance::TYPE  ADVANCE_TYPE,
        bool                           express = false,
        bool                            in_inv = false,
        bool                            out_inv = false)
    {
        cudaError_t retval = cudaSuccess;
        bool over_sized = false;
        if (retval = Check_Size<Enactor::SIZE_CHECK, SizeT, SizeT> (
            "scanned_edges", frontier_attribute->queue_length, partitioned_scanned_edges, over_sized, -1, -1, -1, false)) return retval;
        retval = gunrock::oprtr::advance::ComputeOutputLength
            <AdvanceKernelPolicy, Problem, ForwardFunctor>(
            frontier_attribute,
            d_offsets,
            d_indices,
            d_inv_offsets,
            d_inv_indices,
            d_in_key_queue,
            partitioned_scanned_edges->GetPointer(util::DEVICE),
            max_in,
            max_out,
            context,
            stream,
            ADVANCE_TYPE,
            express,
            in_inv,
            out_inv);
        return retval;
    }

    /*
     * @brief Check frontier queue size function.
     *
     * @param[in] thread_num Number of threads.
     * @param[in] peer_ Peer GPU index.
     * @param[in] request_length Request frontier queue length.
     * @param[in] frontier_queue Pointer to the frontier queue.
     * @param[in] frontier_attribute Pointer to the frontier attribute.
     * @param[in] enactor_stats Pointer to the enactor statistics.
     * @param[in] graph_slice Pointer to the graph slice we process on.
     */
    static void Check_Queue_Size(
        int                            thread_num,
        int                            peer_,
        SizeT                          request_length,
        util::DoubleBuffer<SizeT, VertexId, Value>
                                      *frontier_queue,
        FrontierAttribute<SizeT>      *frontier_attribute,
        EnactorStats                  *enactor_stats,
        GraphSlice                    *graph_slice)
    {
        bool over_sized = false;
        int  selector   = frontier_attribute->selector;
        int  iteration  = enactor_stats -> iteration;

        if (Enactor::DEBUG)
            printf("%d\t %d\t %d\t queue_length = %d, output_length = %d, @ %d\n",
                thread_num, iteration, peer_,
                frontier_queue->keys[selector^1].GetSize(),
                request_length, selector);fflush(stdout);

        if (enactor_stats->retval =
            Check_Size<true, SizeT, VertexId > ("queue3", request_length, &frontier_queue->keys  [selector^1], over_sized, thread_num, iteration, peer_, false)) return;
        if (enactor_stats->retval =
            Check_Size<true, SizeT, VertexId > ("queue3", graph_slice->nodes+2, &frontier_queue->keys  [selector  ], over_sized, thread_num, iteration, peer_, true )) return;
        if (Problem::USE_DOUBLE_BUFFER)
        {
            if (enactor_stats->retval =
                Check_Size<true, SizeT, Value> ("queue3", request_length, &frontier_queue->values[selector^1], over_sized, thread_num, iteration, peer_, false)) return;
            if (enactor_stats->retval =
                Check_Size<true, SizeT, Value> ("queue3", graph_slice->nodes+2, &frontier_queue->values[selector  ], over_sized, thread_num, iteration, peer_, true )) return;
        }
    }
};

/*
 * @brief Iteration structure derived from IterationBase.
 *
 * @tparam AdvanceKernelPolicy Kernel policy for advance operator.
 * @tparam FilterKernelPolicy Kernel policy for filter operator.
 * @tparam Enactor Enactor we process on.
 */
template <typename AdvanceKernelPolicy, typename FilterKernelPolicy, typename Enactor>
struct Backward_Iteration : public IterationBase <
    AdvanceKernelPolicy, FilterKernelPolicy, Enactor,
    false, //HAS_SUBQ
    true , //HAS_FULLQ
    true , //BACKWARD
    false, //FORWARD
    false> //UPDATE_PREDECESSORS
{
public:
    typedef typename Enactor::SizeT      SizeT     ;
    typedef typename Enactor::Value      Value     ;
    typedef typename Enactor::VertexId   VertexId  ;
    typedef typename Enactor::Problem    Problem ;
    typedef typename Problem::DataSlice  DataSlice ;
    typedef GraphSlice<SizeT, VertexId, Value> GraphSlice;
    typedef BackwardFunctor<
            VertexId,
            SizeT,
            Value,
            Problem> BackwardFunctor;
   typedef BackwardFunctor2<
            VertexId,
            SizeT,
            Value,
            Problem> BackwardFunctor2;

    /*
     * @brief FullQueue_Gather function.
     *
     * @param[in] thread_num Number of threads.
     * @param[in] peer_ Peer GPU index.
     * @param[in] frontier_queue Pointer to the frontier queue.
     * @param[in] partitioned_scanned_edges Pointer to the scanned edges.
     * @param[in] frontier_attribute Pointer to the frontier attribute.
     * @param[in] enactor_stats Pointer to the enactor statistics.
     * @param[in] data_slice Pointer to the data slice we process on.
     * @param[in] d_data_slice Pointer to the data slice on the device.
     * @param[in] graph_slice Pointer to the graph slice we process on.
     * @param[in] work_progress Pointer to the work progress class.
     * @param[in] context CudaContext for ModernGPU API.
     * @param[in] stream CUDA stream.
     */
    static void FullQueue_Gather(
        int                            thread_num,
        int                            peer_,
        util::DoubleBuffer<SizeT, VertexId, Value>
                                      *frontier_queue,
        util::Array1D<SizeT, SizeT>   *scanned_edges,
        FrontierAttribute<SizeT>      *frontier_attribute,
        EnactorStats                  *enactor_stats,
        DataSlice                     *data_slice,
        DataSlice                     *d_data_slice,
        GraphSlice                    *graph_slice,
        util::CtaWorkProgressLifetime *work_progress,
        ContextPtr                     context,
        cudaStream_t                   stream)
    {
        SizeT cur_pos = data_slice->forward_queue_offsets[peer_].back();
        data_slice->forward_queue_offsets[peer_].pop_back();
        SizeT pre_pos = data_slice->forward_queue_offsets[peer_].back();
        frontier_attribute->queue_reset  = true;
        frontier_attribute->selector     = 0;//frontier_queue->keys[0].GetSize() > frontier_queue->keys[1].GetSize() ? 1 : 0;
        if (enactor_stats->iteration>0 && cur_pos - pre_pos >0)
        {
            frontier_attribute->queue_length = cur_pos - pre_pos;
            bool over_sized = false;
            if (enactor_stats->retval = Check_Size<Enactor::SIZE_CHECK, SizeT, VertexId> (
                "queue1", frontier_attribute->queue_length, &frontier_queue->keys[frontier_queue->selector], over_sized, thread_num, enactor_stats->iteration, peer_, false)) return;
           util::MemsetCopyVectorKernel<<<256, 256, 0, stream>>>(
                frontier_queue->keys[frontier_queue->selector].GetPointer(util::DEVICE),
                data_slice ->forward_output[peer_].GetPointer(util::DEVICE) + pre_pos,
                frontier_attribute->queue_length);
        }
        else frontier_attribute->queue_length = 0;
    }

    /*
     * @brief FullQueue_Core function.
     *
     * @param[in] thread_num Number of threads.
     * @param[in] peer_ Peer GPU index.
     * @param[in] frontier_queue Pointer to the frontier queue.
     * @param[in] partitioned_scanned_edges Pointer to the scanned edges.
     * @param[in] frontier_attribute Pointer to the frontier attribute.
     * @param[in] enactor_stats Pointer to the enactor statistics.
     * @param[in] data_slice Pointer to the data slice we process on.
     * @param[in] d_data_slice Pointer to the data slice on the device.
     * @param[in] graph_slice Pointer to the graph slice we process on.
     * @param[in] work_progress Pointer to the work progress class.
     * @param[in] context CudaContext for ModernGPU API.
     * @param[in] stream CUDA stream.
     */
    static void FullQueue_Core(
        int                            thread_num,
        int                            peer_,
        util::DoubleBuffer<SizeT, VertexId, Value>
                                      *frontier_queue,
        util::Array1D<SizeT, SizeT>   *scanned_edges,
        FrontierAttribute<SizeT>      *frontier_attribute,
        EnactorStats                  *enactor_stats,
        DataSlice                     *data_slice,
        DataSlice                     *d_data_slice,
        GraphSlice                    *graph_slice,
        util::CtaWorkProgressLifetime *work_progress,
        ContextPtr                     context,
        cudaStream_t                   stream)
    {
       /*frontier_attribute.queue_length        = graph_slice->nodes;
        // Fill in the frontier_queues
        util::MemsetIdxKernel<<<128, 128>>>(graph_slice->frontier_queues.d_keys[0], graph_slice->nodes);
        // Filter
        gunrock::oprtr::filter::Kernel<FilterKernelPolicy, BCProblem, BackwardFunctor>
        <<<enactor_stats.filter_grid_size, FilterKernelPolicy::THREADS>>>(
            -1,
            frontier_attribute.queue_reset,
            frontier_attribute.queue_index,
            enactor_stats.num_gpus,
            frontier_attribute.queue_length,
            d_done,
            graph_slice->frontier_queues.d_keys[0],      // d_in_queue
            NULL,
            graph_slice->frontier_queues.d_keys[1],    // d_out_queue
            data_slice,
            NULL,
            work_progress,
            graph_slice->nodes,           // max_in_queue
            graph_slice->edges,         // max_out_queue
            enactor_stats.filter_kernel_stats);*/

        // Only need to reset queue for once
        /*if (frontier_attribute.queue_reset)
            frontier_attribute.queue_reset = false; */

        //if (/*DEBUG &&*/ (retval = util::GRError(cudaThreadSynchronize(), "edge_map_backward::Kernel failed", __FILE__, __LINE__))) break;
        /*cudaEventQuery(throttle_event);                                 // give host memory mapped visibility to GPU updates
        frontier_attribute.queue_index++;
        frontier_attribute.selector ^= 1;
        if (AdvanceKernelPolicy::ADVANCE_MODE == gunrock::oprtr::advance::LB) {
            if (retval = work_progress.GetQueueLength(frontier_attribute.queue_index, frontier_attribute.queue_length)) break;
            }
        if (DEBUG) {
            if (retval = work_progress.GetQueueLength(frontier_attribute.queue_index, frontier_attribute.queue_length)) break;
            printf(", %lld", (long long) frontier_attribute.queue_length);
        }
        if (INSTRUMENT) {
            if (retval = enactor_stats.advance_kernel_stats.Accumulate(
                enactor_stats.advance_grid_size,
                enactor_stats.total_runtimes,
                enactor_stats.total_lifetimes)) break;
        }
        // Throttle
        if (enactor_stats.iteration & 1) {
            if (retval = util::GRError(cudaEventRecord(throttle_event),
                "BCEnactor cudaEventRecord throttle_event failed", __FILE__, __LINE__)) break;
        } else {
            if (retval = util::GRError(cudaEventSynchronize(throttle_event),
                "BCEnactor cudaEventSynchronize throttle_event failed", __FILE__, __LINE__)) break;
        }
        // Check if done
        if (done[0] == 0) break;*/

        // Edge Map
        if (enactor_stats->iteration > 0) {
            gunrock::oprtr::advance::LaunchKernel<AdvanceKernelPolicy, Problem, BackwardFunctor>(
                enactor_stats[0],
                frontier_attribute[0],
                d_data_slice,
                (VertexId*)NULL,
                (bool*)NULL,
                (bool*)NULL,
                scanned_edges->GetPointer(util::DEVICE),
                frontier_queue->keys[frontier_attribute->selector  ].GetPointer(util::DEVICE),              // d_in_queue
                NULL, //frontier_queue->keys[frontier_attribute->selector^1].GetPointer(util::DEVICE),// d_out_queue
                (VertexId*)NULL,
                (VertexId*)NULL,
                graph_slice->row_offsets   .GetPointer(util::DEVICE),
                graph_slice->column_indices.GetPointer(util::DEVICE),
                (SizeT*)NULL,
                (VertexId*)NULL,
                graph_slice->nodes,                 // max_in_queue
                graph_slice->edges,                 // max_out_queue
                work_progress[0],
                context[0],
                stream,
                gunrock::oprtr::advance::V2V,
                false,
                false,
                false);
        } else {
            gunrock::oprtr::advance::LaunchKernel<AdvanceKernelPolicy, Problem, BackwardFunctor2>(
                enactor_stats[0],
                frontier_attribute[0],
                d_data_slice,
                (VertexId*)NULL,
                (bool*)NULL,
                (bool*)NULL,
                scanned_edges->GetPointer(util::DEVICE),
                frontier_queue->keys[frontier_attribute->selector  ].GetPointer(util::DEVICE),              // d_in_queue
                NULL, //frontier_queue->keys[frontier_attribute->selector^1].GetPointer(util::DEVICE),// d_out_queue
                (VertexId*)NULL,
                (VertexId*)NULL,
                graph_slice->row_offsets   .GetPointer(util::DEVICE),
                graph_slice->column_indices.GetPointer(util::DEVICE),
                (SizeT*)NULL,
                (VertexId*)NULL,
                graph_slice->nodes,                 // max_in_queue
                graph_slice->edges,                 // max_out_queue
                work_progress[0],
                context[0],
                stream,
                gunrock::oprtr::advance::V2V,
                false,
                false,
                false);
        }

    }

    /*
     * @brief Expand incoming function.
     *
     * @tparam NUM_VERTEX_ASSOCIATES
     * @tparam NUM_VALUE__ASSOCIATES
     *
     * @param[in] grid_size
     * @param[in] block_size
     * @param[in] shared_size
     * @param[in] stream
     * @param[in] num_elements
     * @param[in] keys_in
     * @param[in] keys_out
     * @param[in] array_size
     * @param[in] array
     * @param[in] data_slice
     *
     */
    template <int NUM_VERTEX_ASSOCIATES, int NUM_VALUE__ASSOCIATES>
    static void Expand_Incoming(
        int             grid_size,
        int             block_size,
        size_t          shared_size,
        cudaStream_t    stream,
        SizeT           &num_elements,
        VertexId*       keys_in,
        util::Array1D<SizeT, VertexId>* keys_out,
        const size_t    array_size,
        char*           array,
        DataSlice*      data_slice)
    {
        bool over_sized = false;
        Check_Size<Enactor::SIZE_CHECK, SizeT, VertexId>(
            "queue1", num_elements, keys_out, over_sized, -1, -1, -1);
        Expand_Incoming_Backward
            <VertexId, SizeT, Value, NUM_VERTEX_ASSOCIATES, NUM_VALUE__ASSOCIATES>
            <<<grid_size, block_size, shared_size, stream>>> (
            num_elements,
            keys_in,
            keys_out->GetPointer(util::DEVICE),
            array_size,
            array);
    }

    /*
     * @brief Compute output queue length function.
     *
     * @param[in] frontier_attribute Pointer to the frontier attribute.
     * @param[in] d_offsets Pointer to the offsets.
     * @param[in] d_indices Pointer to the indices.
     * @param[in] d_in_key_queue Pointer to the input mapping queue.
     * @param[in] partitioned_scanned_edges Pointer to the scanned edges.
     * @param[in] max_in Maximum input queue size.
     * @param[in] max_out Maximum output queue size.
     * @param[in] context CudaContext for ModernGPU API.
     * @param[in] stream CUDA stream.
     * @param[in] ADVANCE_TYPE Advance kernel mode.
     * @param[in] express Whether or not enable express mode.
     *
     * \return cudaError_t object Indicates the success of all CUDA calls.
     */
    static cudaError_t Compute_OutputLength(
        FrontierAttribute<SizeT>       *frontier_attribute,
        SizeT                          *d_offsets,
        VertexId                       *d_indices,
        SizeT                          *d_inv_offsets,
        VertexId                       *d_inv_indices,
        VertexId                       *d_in_key_queue,
        util::Array1D<SizeT, SizeT>    *partitioned_scanned_edges,
        SizeT                          max_in,
        SizeT                          max_out,
        CudaContext                    &context,
        cudaStream_t                   stream,
        gunrock::oprtr::advance::TYPE  ADVANCE_TYPE,
        bool                           express = false,
        bool                           in_inv = false,
        bool                           out_inv = false)
    {
        cudaError_t retval = cudaSuccess;
        bool over_sized = false;
        if (retval = Check_Size<Enactor::SIZE_CHECK, SizeT, SizeT> (
            "scanned_edges", frontier_attribute->queue_length, partitioned_scanned_edges, over_sized, -1, -1, -1, false)) return retval;
        retval = gunrock::oprtr::advance::ComputeOutputLength
            <AdvanceKernelPolicy, Problem, BackwardFunctor>(
            frontier_attribute,
            d_offsets,
            d_indices,
            d_inv_offsets,
            d_inv_indices,
            d_in_key_queue,
            partitioned_scanned_edges->GetPointer(util::DEVICE),
            max_in,
            max_out,
            context,
            stream,
            ADVANCE_TYPE,
            express,
            in_inv,
            out_inv);
        return retval;
    }

    static void Iteration_Change(long long &iterations)
    {
        iterations--;
    }

    /*
     * @brief Stop_Condition check function.
     *
     * @param[in] enactor_stats Pointer to the enactor statistics.
     * @param[in] frontier_attribute Pointer to the frontier attribute.
     * @param[in] data_slice Pointer to the data slice we process on.
     * @param[in] num_gpus Number of GPUs used.
     */
    static bool Stop_Condition(
        EnactorStats *enactor_stats,
        FrontierAttribute<SizeT> *frontier_attribute,
        util::Array1D<SizeT, DataSlice> *data_slice,
        int num_gpus)
    {
        for (int gpu=0;gpu<num_gpus*num_gpus;gpu++)
        if (enactor_stats[gpu].retval!=cudaSuccess)
        {
            printf("(CUDA error %d @ GPU %d: %s\n", enactor_stats[gpu].retval, gpu, cudaGetErrorString(enactor_stats[gpu].retval)); fflush(stdout);
            return true;
        }
        if (All_Done(enactor_stats, frontier_attribute, data_slice, num_gpus))
        {
            for (int gpu=0;gpu<num_gpus*num_gpus;gpu++)
            if (enactor_stats[gpu].iteration>1) {
                return false;
            }
            return true;
        } else return false;
    }

    /*
     * @brief Check frontier queue size function.
     *
     * @param[in] thread_num Number of threads.
     * @param[in] peer_ Peer GPU index.
     * @param[in] request_length Request frontier queue length.
     * @param[in] frontier_queue Pointer to the frontier queue.
     * @param[in] frontier_attribute Pointer to the frontier attribute.
     * @param[in] enactor_stats Pointer to the enactor statistics.
     * @param[in] graph_slice Pointer to the graph slice we process on.
     */
    static void Check_Queue_Size(
        int                            thread_num,
        int                            peer_,
        SizeT                          request_length,
        util::DoubleBuffer<SizeT, VertexId, Value>
                                      *frontier_queue,
        FrontierAttribute<SizeT>      *frontier_attribute,
        EnactorStats                  *enactor_stats,
        GraphSlice                    *graph_slice)
    {
        return;
        /*bool over_sized = false;
        int  selector   = frontier_attribute->selector;
        int  iteration  = enactor_stats -> iteration;

        if (Enactor::DEBUG)
            printf("%d\t %d\t %d\t queue_length = %d, output_length = %d\n",
                thread_num, iteration, peer_,
                frontier_queue->keys[selector^1].GetSize(),
                request_length);fflush(stdout);

        if (enactor_stats->retval =
            Check_Size<true, SizeT, VertexId > ("queue3", request_length, &frontier_queue->keys  [selector^1], over_sized, thread_num, iteration, peer_, false)) return;
        if (enactor_stats->retval =
            Check_Size<true, SizeT, VertexId > ("queue3", graph_slice->nodes+2, &frontier_queue->keys  [selector  ], over_sized, thread_num, iteration, peer_, true )) return;
        if (Problem::USE_DOUBLE_BUFFER)
        {
            if (enactor_stats->retval =
                Check_Size<true, SizeT, Value> ("queue3", request_length, &frontier_queue->values[selector^1], over_sized, thread_num, iteration, peer_, false)) return;
            if (enactor_stats->retval =
                Check_Size<true, SizeT, Value> ("queue3", graph_slice->nodes+2, &frontier_queue->values[selector  ], over_sized, thread_num, iteration, peer_, true )) return;
        } */
    }
};

/**
 * @brief Thread controls.
 *
 * @tparam AdvanceKernelPolicy Kernel policy for advance operator.
 * @tparam FilterKernelPolicy Kernel policy for filter operator.
 * @tparam BcEnactor Enactor type we process on.
 *
 * @thread_data_ Thread data.
 */
template <
    typename AdvanceKernelPolicy,
    typename FilterKernelPolicy,
    typename BcEnactor>
static CUT_THREADPROC BCThread(
    void * thread_data_)
{
    typedef typename BcEnactor::Problem    Problem;
    typedef typename BcEnactor::SizeT      SizeT;
    typedef typename BcEnactor::VertexId   VertexId;
    typedef typename BcEnactor::Value      Value;
    typedef typename Problem::DataSlice  DataSlice;
    typedef GraphSlice<SizeT, VertexId, Value> GraphSlice;
    typedef ForwardFunctor<VertexId, SizeT, Value, Problem> BcFFunctor;
    typedef BackwardFunctor<VertexId, SizeT, Value, Problem> BcBFunctor;

    ThreadSlice  *thread_data         =  (ThreadSlice*) thread_data_;
    Problem      *problem             =  (Problem*)     thread_data->problem;
    BcEnactor    *enactor             =  (BcEnactor*)   thread_data->enactor;
    util::cpu_mt::CPUBarrier
                 *cpu_barrier         =   thread_data->cpu_barrier;
    int           num_gpus            =   problem     -> num_gpus;
    int           thread_num          =   thread_data -> thread_num;
    int           gpu_idx             =   problem     -> gpu_idx            [thread_num] ;
    DataSlice    *data_slice          =   problem     -> data_slices        [thread_num].GetPointer(util::HOST);
    util::Array1D<SizeT, DataSlice>
                 *s_data_slice        =   problem     -> data_slices;
    GraphSlice   *graph_slice         =   problem     -> graph_slices       [thread_num] ;
    FrontierAttribute<SizeT>
                 *frontier_attribute  = &(enactor     -> frontier_attribute [thread_num * num_gpus]);
    EnactorStats *enactor_stats       = &(enactor     -> enactor_stats      [thread_num * num_gpus]);
    EnactorStats *s_enactor_stats     = &(enactor     -> enactor_stats      [0                    ]);

    do {
        if (enactor_stats[0].retval = util::SetDevice(gpu_idx)) break;
        thread_data->stats = 1;
        while (thread_data->stats !=2) sleep(0);
        thread_data->stats = 3;

        for (int peer_=0;peer_<num_gpus;peer_++)
        {
            frontier_attribute[peer_].queue_index  = 0;        // Work queue index
            frontier_attribute[peer_].queue_length = peer_==0 ? thread_data -> init_size : 0; //?
            frontier_attribute[peer_].selector     = frontier_attribute[peer_].queue_length == 0? 0:1;
            frontier_attribute[peer_].queue_reset  = true;
            enactor_stats     [peer_].iteration    = 0;
        }

        if (num_gpus>1)
        {
            data_slice->vertex_associate_orgs[0]=data_slice->labels.GetPointer(util::DEVICE);
            data_slice->vertex_associate_orgs[1]=data_slice->preds.GetPointer(util::DEVICE);
            data_slice->value__associate_orgs[0]=data_slice->sigmas.GetPointer(util::DEVICE);
            data_slice->vertex_associate_orgs.Move(util::HOST, util::DEVICE);
            data_slice->value__associate_orgs.Move(util::HOST, util::DEVICE);
        }
        gunrock::app::Iteration_Loop
            <2, 1, BcEnactor, BcFFunctor, Forward_Iteration<AdvanceKernelPolicy, FilterKernelPolicy, BcEnactor> > (thread_data);
        if (BcEnactor::DEBUG) util::cpu_mt::PrintMessage("Forward phase finished.", thread_num, enactor_stats->iteration);

        if (num_gpus>1)
        {
            data_slice->sigmas.Move(util::DEVICE, util::HOST);
            data_slice->labels.Move(util::DEVICE, util::HOST);
            //CPU_Barrier;
            util::cpu_mt::IncrementnWaitBarrier(&cpu_barrier[0],thread_num);
            long max_iteration=0;
            for (int gpu=0;gpu<num_gpus;gpu++)
            {
                if (s_enactor_stats[gpu*num_gpus].iteration>max_iteration)
                    max_iteration=s_enactor_stats[gpu*num_gpus].iteration;
            }
            while (data_slice->forward_queue_offsets[0].size()<max_iteration)
            {
                data_slice->forward_queue_offsets[0].push_back(data_slice->forward_queue_offsets[0].back());
            }
            enactor_stats[0].iteration=max_iteration;
            for (VertexId node=0;node<graph_slice->in_counter[0];node++)
            {
                for (SizeT i=graph_slice->backward_offset[node];i<graph_slice->backward_offset[node+1];i++)
                {
                    int peer = graph_slice->backward_partition[i];
                    if (peer<=thread_num) peer--;
                    int _node = graph_slice->backward_convertion[i];
                    s_data_slice[peer]->sigmas[_node]=data_slice->sigmas[node];
                    s_data_slice[peer]->labels[_node]=data_slice->labels[node];
                }
            }
            //CPU_Barrier;
            util::cpu_mt::IncrementnWaitBarrier(&cpu_barrier[1],thread_num);
            for (int i=0;i<num_gpus;i++)
            for (int j=0;j<4;j++)
            for (int k=0;k<4;k++)
                data_slice->events_set[j][i][k]=false;
            data_slice->sigmas.Move(util::HOST, util::DEVICE);
            data_slice->labels.Move(util::HOST, util::DEVICE);
            data_slice->value__associate_orgs[0]=data_slice->deltas.GetPointer(util::DEVICE);
            data_slice->value__associate_orgs[1]=data_slice->bc_values.GetPointer(util::DEVICE);
            data_slice->value__associate_orgs.Move(util::HOST, util::DEVICE);
        } else {
        }

        gunrock::app::Iteration_Loop
            <0, 2, BcEnactor, BcBFunctor, Backward_Iteration<AdvanceKernelPolicy, FilterKernelPolicy, BcEnactor> > (thread_data);
        if (BcEnactor::DEBUG) util::cpu_mt::PrintMessage("Backward phase finished.", thread_num, enactor_stats->iteration);
   } while (0);

   thread_data->stats=4;
   CUT_THREADEND;
}

/**
 * @brief Problem enactor class.
 *
 * @tparam _Problem Problem type we process on
 * @tparam _INSTRUMENT Whether or not to collect per-CTA clock-count stats.
 * @tparam _DEBUG Whether or not to enable debug mode.
 * @tparam _SIZE_CHECK Whether or not to enable size check.
 */
template<typename _Problem, bool _INSTRUMENT, bool _DEBUG, bool _SIZE_CHECK>
class BCEnactor :
    public EnactorBase<typename _Problem::SizeT, _DEBUG, _SIZE_CHECK>
{
     // Members
    _Problem    *problem      ;
    ThreadSlice *thread_slices;
    CUTThread   *thread_Ids   ;
    util::cpu_mt::CPUBarrier *cpu_barrier;

    // Methods
public:
    typedef _Problem                   Problem;
    typedef typename Problem::SizeT    SizeT   ;
    typedef typename Problem::VertexId VertexId;
    typedef typename Problem::Value    Value   ;
    static const bool INSTRUMENT = _INSTRUMENT;
    static const bool DEBUG      = _DEBUG;
    static const bool SIZE_CHECK = _SIZE_CHECK;

   /**
     * \addtogroup PublicInterface
     * @{
     */

    /**
     * @brief BCEnactor constructor
     */
    BCEnactor(int num_gpus = 1, int* gpu_idx = NULL) :
        EnactorBase<SizeT, _DEBUG, _SIZE_CHECK>(VERTEX_FRONTIERS, num_gpus, gpu_idx)
    {
        thread_slices = NULL;
        thread_Ids    = NULL;
        problem       = NULL;
        cpu_barrier   = NULL;
    }

    /**
     *  @brief BCenactor destructor
     */
    virtual ~BCEnactor()
    {
        cutWaitForThreads(thread_Ids, this->num_gpus);
        delete[] thread_Ids   ; thread_Ids    = NULL;
        delete[] thread_slices; thread_slices = NULL;
        problem = NULL;
        if (cpu_barrier!=NULL)
        {
            util::cpu_mt::DestoryBarrier(&cpu_barrier[0]);
            util::cpu_mt::DestoryBarrier(&cpu_barrier[1]);
            delete[] cpu_barrier;cpu_barrier=NULL;
        }
    }

    /**
     * @brief Obtain statistics about the last primitive enacted.
     *
     * @param[out] total_queued Total queued elements in kernel running.
     * @param[out] avg_duty Average kernel duty (kernel time/kernel lifetime).
     */
    void GetStatistics(
        long long &total_queued,
        double    &avg_duty)
    {
        unsigned long long total_lifetimes = 0;
        unsigned long long total_runtimes  = 0;
        total_queued = 0;
        //search_depth = 0;
        for (int gpu=0;gpu<this->num_gpus;gpu++)
        {
            if (this->num_gpus!=1)
                if (util::SetDevice(this->gpu_idx[gpu])) return;
            cudaThreadSynchronize();

            for (int peer=0; peer< this->num_gpus; peer++)
            {
                EnactorStats *enactor_stats_ = this->enactor_stats + gpu * this->num_gpus + peer;
                enactor_stats_ -> total_queued.Move(util::DEVICE, util::HOST);
                total_queued += enactor_stats_ -> total_queued[0];
                /*if (this->enactor_stats[gpu].iteration > search_depth)
                    search_depth = this->enactor_stats[gpu].iteration;*/
                total_lifetimes += enactor_stats_ ->total_lifetimes;
                total_runtimes  += enactor_stats_ ->total_runtimes;
            }
        }
        avg_duty = (total_lifetimes > 0) ?
            double(total_runtimes) / total_lifetimes : 0.0;
    }

    /**
     * @brief Initialize the problem.
     *
     * @tparam AdvanceKernelPolicy Kernel policy for advance operator.
     * @tparam FilterKernelPolicy Kernel policy for filter operator.
     *
     * @param[in] context CudaContext pointer for ModernGPU API.
     * @param[in] problem Pointer to Problem object.
     * @param[in] max_grid_size Maximum grid size for kernel calls.
     * @param[in] size_check Whether or not to enable size check.
     *
     * \return cudaError_t object Indicates the success of all CUDA calls.
     */
    template<
        typename AdvanceKernelPolity,
        typename FilterKernelPolicy>
    cudaError_t InitBC(
        ContextPtr  *context,
        Problem     *problem,
        int         max_grid_size = 512,
        bool        size_check    = true)
    {
        cudaError_t retval = cudaSuccess;
        cpu_barrier = new util::cpu_mt::CPUBarrier[2];
        cpu_barrier[0]=util::cpu_mt::CreateBarrier(this->num_gpus);
        cpu_barrier[1]=util::cpu_mt::CreateBarrier(this->num_gpus);
        // Lazy initialization
        if (retval = EnactorBase<SizeT, DEBUG, SIZE_CHECK>::Init(problem,
                                       max_grid_size,
                                       AdvanceKernelPolity::CTA_OCCUPANCY,
                                       FilterKernelPolicy::CTA_OCCUPANCY)) return retval;

        this->problem = problem;
        thread_slices = new ThreadSlice [this->num_gpus];
        thread_Ids    = new CUTThread   [this->num_gpus];

        for (int gpu=0;gpu<this->num_gpus;gpu++)
        {
            thread_slices[gpu].cpu_barrier  = cpu_barrier;
            thread_slices[gpu].thread_num   = gpu;
            thread_slices[gpu].problem      = (void*)problem;
            thread_slices[gpu].enactor      = (void*)this;
            thread_slices[gpu].context      =&(context[gpu*this->num_gpus]);
            thread_slices[gpu].stats        = -1;
            thread_slices[gpu].thread_Id = cutStartThread(
                (CUT_THREADROUTINE)&(BCThread<
                    AdvanceKernelPolity, FilterKernelPolicy,
                    BCEnactor<Problem, INSTRUMENT, DEBUG, SIZE_CHECK> >),
                    (void*)&(thread_slices[gpu]));
            thread_Ids[gpu] = thread_slices[gpu].thread_Id;
        }
        return retval;
    }

    /**
     * @brief Reset enactor
     *
     * \return cudaError_t object Indicates the success of all CUDA calls.
     */
    cudaError_t Reset()
    {
        return EnactorBase<SizeT,DEBUG,SIZE_CHECK>::Reset();
    }

    /** @} */

    /**
     * @brief Enacts a betweenness-centrality computing on the specified graph.
     *
     * @tparam AdvanceKernelPolicy Kernel policy for advance operator.
     * @tparam FilterKernelPolicy Kernel policy for filter operator.
     *
     * @param[in] src Source node to start primitive.
     *
     * \return cudaError_t object Indicates the success of all CUDA calls.
     */
    template<
        typename AdvanceKernelPolicy,
        typename FilterKernelPolicy>
    cudaError_t EnactBC(VertexId    src)
    {
        cudaError_t              retval         = cudaSuccess;

        do {
            for (int gpu=0;gpu<this->num_gpus;gpu++)
            {
                if ((this->num_gpus ==1) || (gpu==this->problem->partition_tables[0][src]))
                {
                    //printf("src = %d gpu = %d\n", src, gpu);fflush(stdout);
                    thread_slices[gpu].init_size=1;
                } else thread_slices[gpu].init_size=0;
                //this->frontier_attribute[gpu*this->num_gpus].queue_length = thread_slices[gpu].init_size;
            }

            for (int gpu=0; gpu< this->num_gpus; gpu++)
            {
                while (thread_slices[gpu].stats!=1) sleep(0);
                thread_slices[gpu].stats=2;
            }
            for (int gpu=0; gpu< this->num_gpus; gpu++)
            {
                while (thread_slices[gpu].stats!=4) sleep(0);
            }

            for (int gpu=0;gpu< this->num_gpus;gpu++)
                if (this->enactor_stats[gpu].retval!=cudaSuccess)
                {retval=this->enactor_stats[gpu].retval;break;}
        } while (0);
        if (DEBUG) printf("\nGPU BC Done.\n");
        return retval;
    }

    /**
     * \addtogroup PublicInterface
     * @{
     */

    typedef gunrock::oprtr::filter::KernelPolicy<
        Problem,                            // Problem data type
        300,                                // CUDA_ARCH
        INSTRUMENT,                         // INSTRUMENT
        0,                                  // SATURATION QUIT
        true,                               // DEQUEUE_PROBLEM_SIZE
        8,                                  // MIN_CTA_OCCUPANCY
        8,                                  // LOG_THREADS
        1,                                  // LOG_LOAD_VEC_SIZE
        0,                                  // LOG_LOADS_PER_TILE
        5,                                  // LOG_RAKING_THREADS
        5,                                  // END BIT_MASK (no bitmask cull in BC)
        8>                                  // LOG_SCHEDULE_GRANULARITY
    FilterKernelPolicy;

    typedef gunrock::oprtr::advance::KernelPolicy<
        Problem,                            // Problem data type
        300,                                // CUDA_ARCH
        INSTRUMENT,                         // INSTRUMENT
        1,                                  // MIN_CTA_OCCUPANCY
        10,                                 // LOG_THREADS
        8,                                  // LOG_BLOCKS
        32*128,                             // LIGHT_EDGE_THRESHOLD (used for partitioned advance mode)
        1,                                  // LOG_LOAD_VEC_SIZE
        0,                                  // LOG_LOADS_PER_TILE
        5,                                  // LOG_RAKING_THREADS
        32,                                 // WARP_GATHER_THRESHOLD
        128 * 4,                            // CTA_GATHER_THRESHOLD
        7,                                  // LOG_SCHEDULE_GRANULARITY
        gunrock::oprtr::advance::LB>
    AdvanceKernelPolicy;

    /**
     * @brief BC Enact kernel entry.
     *
     * @param[in] src Source node to start primitive.
     *
     * \return cudaError_t object Indicates the success of all CUDA calls.
     */
    cudaError_t Enact(VertexId src)
    {
        int min_sm_version = -1;
        for (int i=0;i<this->num_gpus;i++)
        {
            if (min_sm_version == -1 ||
                this->cuda_props[i].device_sm_version < min_sm_version)
                min_sm_version = this->cuda_props[i].device_sm_version;
        }

        if (min_sm_version >= 300)
        {
            return EnactBC<AdvanceKernelPolicy, FilterKernelPolicy>(src);
        }

        //to reduce compile time, get rid of other architecture for now
        //TODO: add all the kernel policy settings for all archs
        printf("Not yet tuned for this architecture\n");
        return cudaErrorInvalidDeviceFunction;
    }

    /**
     * @brief BC Enact kernel entry.
     *
     * @param[in] context CudaContext pointer for ModernGPU API.
     * @param[in] problem Pointer to Problem object.
     * @param[in] max_grid_size Maximum grid size for kernel calls.
     * @param[in] size_check Whether or not to enable size check.
     *
     * \return cudaError_t object Indicates the success of all CUDA calls.
     */
    cudaError_t Init(
        ContextPtr *context,
        Problem    *problem,
        int max_grid_size = 512,
        bool size_check = true)
    {
        int min_sm_version = -1;
        for (int i=0;i<this->num_gpus;i++)
        {
            if (min_sm_version ==-1 ||
                this->cuda_props[i].device_sm_version < min_sm_version)
                min_sm_version = this->cuda_props[i].device_sm_version;
        }

        if (min_sm_version >= 300)
        {
            return InitBC<AdvanceKernelPolicy, FilterKernelPolicy>(
                context, problem, max_grid_size, size_check);
        }

        //to reduce compile time, get rid of other architecture for now
        //TODO: add all the kernel policy settings for all archs
        printf("Not yet tuned for this architecture\n");
        return cudaErrorInvalidDeviceFunction;
    }
    /** @} */

};

} // namespace bc
} // namespace app
} // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
