// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * test_salsa.cu
 *
 * @brief Simple test driver program for using SALSA algorithm to compute rank.
 */

#include <stdio.h>
#include <string>
#include <deque>
#include <vector>
#include <iostream>
#include <cstdlib>

// Utilities and correctness-checking
#include <gunrock/util/test_utils.cuh>

// Graph construction utils
#include <gunrock/graphio/market.cuh>
#include <gunrock/graphio/rmat.cuh>
#include <gunrock/graphio/rgg.cuh>

// SALSA includes
#include <gunrock/app/salsa/salsa_enactor.cuh>
#include <gunrock/app/salsa/salsa_problem.cuh>
#include <gunrock/app/salsa/salsa_functor.cuh>

// Operator includes
#include <gunrock/oprtr/advance/kernel.cuh>
#include <gunrock/oprtr/filter/kernel.cuh>

#include <moderngpu.cuh>

using namespace gunrock;
using namespace gunrock::app;
using namespace gunrock::util;
using namespace gunrock::oprtr;
using namespace gunrock::app::salsa;


/******************************************************************************
 * Defines, constants, globals
 ******************************************************************************/

template <typename VertexId, typename Value>
struct RankPair {
    VertexId        vertex_id;
    Value           page_rank;

    RankPair(VertexId vertex_id, Value page_rank) :
                vertex_id(vertex_id),
                page_rank(page_rank) {}
};

template<typename RankPair>
bool SALSACompare(
    RankPair elem1,
    RankPair elem2)
{
    return elem1.page_rank > elem2.page_rank;
}

/******************************************************************************
 * Housekeeping Routines
 ******************************************************************************/
void Usage()
{
    printf("\ntest_salsa <graph type> <graph type args> [--device=<device_index>] "
           "[--instrumented] [--quick] "
           "[--v]\n"
           "\n"
           "Graph types and args:\n"
           "  market [<file>]\n"
           "    Reads a Matrix-Market coordinate-formatted graph of directed/undirected\n"
           "    edges from stdin (or from the optionally-specified file).\n"
           "  --device=<device_index>  Set GPU device for running the graph primitive.\n"
           "  --instrumented If set then kernels keep track of queue-search_depth\n"
           "  and barrier duty (a relative indicator of load imbalance.)\n"
           "  --quick If set will skip the CPU validation code.\n"
        );
}

/**
 * @brief Displays the BFS result (i.e., distance from source)
 *
 * @param[in] hrank Pointer to hub rank score array
 * @param[in] arank Pointer to authority rank score array
 * @param[in] nodes Number of nodes in the graph.
 */
template<typename Value, typename SizeT>
void DisplaySolution(Value *hrank, Value *arank, SizeT nodes)
{
    //sort the top page ranks
    RankPair<SizeT, Value> *hr_list =
        (RankPair<SizeT, Value>*)malloc(sizeof(RankPair<SizeT, Value>) * nodes);
    RankPair<SizeT, Value> *ar_list =
        (RankPair<SizeT, Value>*)malloc(sizeof(RankPair<SizeT, Value>) * nodes);

    for (int i = 0; i < nodes; ++i)
    {
        hr_list[i].vertex_id = i;
        hr_list[i].page_rank = hrank[i];
        ar_list[i].vertex_id = i;
        ar_list[i].page_rank = arank[i];
    }
    std::stable_sort(
        hr_list, hr_list + nodes, SALSACompare<RankPair<SizeT, Value> >);
    std::stable_sort(
        ar_list, ar_list + nodes, SALSACompare<RankPair<SizeT, Value> >);

    // Print out at most top 10 largest components
    int top = (nodes < 10) ? nodes : 10;
    printf("Top %d Page Ranks:\n", top);
    for (int i = 0; i < top; ++i)
    {
        printf("Vertex ID: %d, Hub Rank: %5f\n", hr_list[i].vertex_id, hr_list[i].page_rank);
        printf("Vertex ID: %d, Authority Rank: %5f\n", ar_list[i].vertex_id, ar_list[i].page_rank);
    }

    free(hr_list);
    free(ar_list);
}

/******************************************************************************
 * SALSA Testing Routines
 *****************************************************************************/

/**
 * @brief A simple CPU-based reference SALSA implementation.
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 *
 * @param[in] graph Reference to the CSR graph we process on
 * @param[in] inv_graph Reference to the inversed CSR graph we process on
 * @param[in] hrank Host-side vector to store CPU computed hub ranks for each node
 * @param[in] arank Host-side vector to store CPU computed authority ranks for each node
 * @param[in] max_iter max iteration to go
 */
template<
    typename VertexId,
    typename Value,
    typename SizeT>
void SimpleReferenceSALSA(
    const Csr<VertexId, Value, SizeT>       &graph,
    const Csr<VertexId, Value, SizeT>       &inv_graph,
    Value                                   *hrank,
    Value                                   *arank,
    SizeT                                   max_iter)
{
    //Preparation

    //
    //compute SALSA rank
    //

    CpuTimer cpu_timer;
    cpu_timer.Start();

    cpu_timer.Stop();
    float elapsed = cpu_timer.ElapsedMillis();

    printf("CPU BFS finished in %lf msec.\n", elapsed);
}

/**
 * @brief Run SALSA tests
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 * @tparam INSTRUMENT
 *
 * @param[in] info Stats and parameter data structure
 *
 */
template <
    typename VertexId,
    typename Value,
    typename SizeT,
    bool INSTRUMENT,
    bool DEBUG,
    bool SIZE_CHECK>
void RunTests(Info<VertexId, Value, SizeT> *info)
{

    typedef SALSAProblem<
        VertexId,
        SizeT,
        Value> Problem;

    Csr<VertexId, Value, SizeT>
                *csr                    = (Csr<VertexId, Value, SizeT>*)info->csr_ptr;
    Csr<VertexId, Value, SizeT>
                *csc                    = (Csr<VertexId, Value, SizeT>*)info->csc_ptr;
    int         max_grid_size           = info->info["max_grid_size"].get_int64();
    int         num_gpus                = info->info["num_gpus"].get_int();
    bool        quiet_mode              = info->info["quiet_mode"].get_bool();
    bool        quick_mode              = info->info["quick_mode"].get_bool();
    SizeT       max_iter                = info->info["max_iteration"].get_int();
    bool        undirected              = info->info["undirected"].get_bool(); 
    bool        stream_from_host        = info->info["stream_from_host"].get_bool();

    json_spirit::mArray device_list = info->info["device_list"].get_array();
    int* gpu_idx = new int[num_gpus];
    for (int i = 0; i < num_gpus; i++) gpu_idx[i] = device_list[i].get_int();

    ContextPtr   *context               = (ContextPtr*)info -> context;

    // Allocate host-side label array (for both reference and gpu-computed results)
    Value    *reference_hrank       = (Value*)malloc(sizeof(Value) * csr->nodes);
    Value    *reference_arank       = (Value*)malloc(sizeof(Value) * csr->nodes);
    Value    *h_hrank               = (Value*)malloc(sizeof(Value) * csr->nodes);
    Value    *h_arank               = (Value*)malloc(sizeof(Value) * csr->nodes);
    Value    *reference_check_h     = (quick_mode) ? NULL : reference_hrank;
    Value    *reference_check_a     = (quick_mode) ? NULL : reference_arank;

    // Allocate BFS enactor map
    SALSAEnactor<Problem, INSTRUMENT, DEBUG, SIZE_CHECK> salsa_enactor(gpu_idx);

    // Allocate problem on GPU
    Problem *problem = new Problem;
    util::GRError(problem->Init(
                      stream_from_host,
                      *csr,
                      *csc,
                      num_gpus),
                  "Problem SALSA Initialization Failed", __FILE__, __LINE__);

    //
    // Compute reference CPU SALSA solution for source-distance
    //
    if (reference_check_h != NULL)
    {
        if (!quiet_mode) { printf("compute ref value\n"); }
        SimpleReferenceSALSA(
            *csr,
            *csc,
            reference_check_h,
            reference_check_a,
            max_iter);
        if (!quiet_mode) printf("\n");
    }

    // Perform BFS
    GpuTimer gpu_timer;

    util::GRError(
        problem->Reset(salsa_enactor.GetFrontierType(), 200.0),
        "SALSA Problem Data Reset Failed", __FILE__, __LINE__);
    gpu_timer.Start();
    util::GRError(
        salsa_enactor.template Enact<Problem>(
            *context, problem, max_iter, max_grid_size),
        "SALSA Problem Enact Failed", __FILE__, __LINE__);
    gpu_timer.Stop();

    double elapsed = gpu_timer.ElapsedMillis();

    // Copy out results
    util::GRError(
        problem->Extract(h_hrank, h_arank),
        "SALSA Problem Data Extraction Failed", __FILE__, __LINE__);

    // Verify the result
    if (reference_check_a != NULL)
    {
        if (!quiet_mode) printf("Validity: ");
        CompareResults(h_hrank, reference_check_h, csr->nodes, true);
        CompareResults(h_arank, reference_check_a, csr->nodes, true);
    }
    if (!quiet_mode) 
    DisplaySolution(h_hrank, h_arank, csr->nodes);

    info->ComputeCommonStats(salsa_enactor.enactor_stats.GetPointer(), elapsed);

    if (!quiet_mode)
        info->DisplayStats();   // display collected statistics

    info->CollectInfo();

    // Cleanup
    if (problem) delete problem;
    if (reference_check_h) free(reference_check_h);
    if (reference_check_a) free(reference_check_a);

    if (h_hrank) free(h_hrank);
    if (h_arank) free(h_arank);

    cudaDeviceSynchronize();
}

template <
    typename      VertexId,
    typename      Value,
    typename      SizeT,
    bool          INSTRUMENT,
    bool          DEBUG>
void RunTests_size_check(Info<VertexId, Value, SizeT> *info)
{

    if (info->info["size_check"].get_bool())
        RunTests<VertexId, Value, SizeT, INSTRUMENT, DEBUG,
        true > (info);
   else RunTests<VertexId, Value, SizeT, INSTRUMENT, DEBUG,
        false> (info);
}

template <
    typename    VertexId,
    typename    Value,
    typename    SizeT,
    bool        INSTRUMENT>
void RunTests_debug(Info<VertexId, Value, SizeT> *info)
{
    if (info->info["debug_mode"].get_bool())
        RunTests_size_check<VertexId, Value, SizeT, INSTRUMENT,
        true > (info);
    else RunTests_size_check
        <VertexId, Value, SizeT, INSTRUMENT,
        false> (info);
}

template <
    typename      VertexId,
    typename      Value,
    typename      SizeT>
void RunTests_instrumented(Info<VertexId, Value, SizeT> *info)
{
    if (info->info["instrument"].get_bool())
        RunTests_debug<VertexId, Value, SizeT,
        true > (info);
    else RunTests_debug
        <VertexId, Value, SizeT,
        false> (info);
}

/******************************************************************************
 * Main
 ******************************************************************************/

int main( int argc, char** argv)
{
    CommandLineArgs args(argc, argv);

    int graph_args = argc - args.ParsedArgc() - 1;
    if ((argc < 2) || (graph_args < 1) || (args.CheckCmdLineFlag("help")))
    {
        Usage();
        return 1;
    }

        typedef int VertexId;                   // Use as the node identifier
        typedef float Value;                    // Use as the value type
        typedef int SizeT;                      // Use as the graph size type

        Csr<VertexId, Value, SizeT> csr(false); // default for stream_from_host
        Csr<VertexId, Value, SizeT> csc(false);
        Info<VertexId, Value, SizeT> *info = new Info<VertexId, Value, SizeT>;

        info->info["undirected"] = false;
        info->info["edge_value"] = false;
 
        info->Init("SALSA", args, csr, csc);

        // TODO: add a CPU Reference SALSA algorithm.
        // before that, quick_mode always on.
        info->info["quick_mode"] = true;
        RunTests_instrumented<VertexId, Value, SizeT>(info);

    
    return 0;
}
