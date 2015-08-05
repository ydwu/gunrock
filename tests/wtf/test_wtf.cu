// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * test_wtf.cu
 *
 * @brief Simple test driver program for computing Pagerank.
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

// BFS includes
#include <gunrock/app/wtf/wtf_enactor.cuh>
#include <gunrock/app/wtf/wtf_problem.cuh>
#include <gunrock/app/wtf/wtf_functor.cuh>

// Operator includes
#include <gunrock/oprtr/advance/kernel.cuh>
#include <gunrock/oprtr/filter/kernel.cuh>

#include <moderngpu.cuh>

// boost includes
#include <boost/config.hpp>
#include <boost/utility.hpp>
#include <boost/graph/adjacency_list.hpp>
#include <boost/graph/page_rank.hpp>


using namespace gunrock;
using namespace gunrock::app;
using namespace gunrock::util;
using namespace gunrock::oprtr;
using namespace gunrock::app::wtf;


/******************************************************************************
 * Defines, constants, globals
 ******************************************************************************/

//bool g_verbose;
//bool g_undirected;
//bool g_quick;
//bool g_stream_from_host;

template <typename VertexId, typename Value>
struct RankPair {
    VertexId        vertex_id;
    Value           page_rank;

    RankPair(VertexId vertex_id, Value page_rank) : vertex_id(vertex_id), page_rank(page_rank) {}
};

template<typename RankPair>
bool PRCompare(
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
    printf("\ntest_wtf <graph type> <graph type args> [--device=<device_index>] "
           "[--undirected] [--instrumented] [--quick] "
           "[--v]\n"
           "\n"
           "Graph types and args:\n"
           "  market [<file>]\n"
           "    Reads a Matrix-Market coordinate-formatted graph of directed/undirected\n"
           "    edges from stdin (or from the optionally-specified file).\n"
           "  --device=<device_index>  Set GPU device for running the graph primitive.\n"
           "  --undirected If set then treat the graph as undirected.\n"
           "  --instrumented If set then kernels keep track of queue-search_depth\n"
           "  and barrier duty (a relative indicator of load imbalance.)\n"
           "  --quick If set will skip the CPU validation code.\n"
        );
}

/**
 * @brief Displays the BFS result (i.e., distance from source)
 *
 * @param[in] node_id Pointer to node ID array
 * @param[in] rank Pointer to node rank score array
 * @param[in] nodes Number of nodes in the graph.
 */
template<typename VertexId, typename Value, typename SizeT>
void DisplaySolution(VertexId *node_id, Value *rank, SizeT nodes)
{
    // Print out at most top 10 largest components
    int top = (nodes < 10) ? nodes : 10;
    printf("Top %d Page Ranks:\n", top);
    for (int i = 0; i < top; ++i)
    {
        printf("Vertex ID: %d, Page Rank: %5f\n", node_id[i], rank[i]);
    }
}

/******************************************************************************
 * WTF Testing Routines
 *****************************************************************************/

/**
 * @brief A simple CPU-based reference WTF implementation.
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 *
 * @param[in] graph Reference to the CSR graph we process on
 * @param[in] src Source node ID for WTF algorithm
 * @param[out] node_id Pointer to store computed output node ID
 * @param[in] rank Host-side vector to store CPU computed labels for each node
 * @param[in] delta Delta value for computing PageRank score
 * @param[in] alpha Parameter to adjust iteration number
 * @param[in] max_iter max iteration to go
 */
// TODO: Boost PageRank cannot handle personalized pagerank, so currently the CPU
// implementation gives incorrect answer. Need to find a CPU PPR implementation
template<
    typename VertexId,
    typename Value,
    typename SizeT>
void SimpleReferenceWTF(
    const Csr<VertexId, Value, SizeT>       &graph,
    VertexId                                src,
    VertexId                                *node_id,
    Value                                   *rank,
    Value                                   delta,
    Value                                   alpha,
    SizeT                                   max_iter)
{
    using namespace boost;

    //Preparation
    typedef adjacency_list<vecS, vecS, bidirectionalS, no_property,
                           property<edge_index_t, int> > Graph;

    Graph g;

    for (int i = 0; i < graph.nodes; ++i)
    {
        for (int j = graph.row_offsets[i]; j < graph.row_offsets[i+1]; ++j)
        {
            Graph::edge_descriptor e =
                add_edge(i, graph.column_indices[j], g).first;
            put(edge_index, g, e, i);
        }
    }


    //
    //compute page rank
    //

    CpuTimer cpu_timer;
    cpu_timer.Start();

    //remove_dangling_links(g);

    std::vector<Value> ranks(num_vertices(g));
    page_rank(g, make_iterator_property_map(
                  ranks.begin(), get(boost::vertex_index, g)),
              boost::graph::n_iterations(max_iter));

    cpu_timer.Stop();
    float elapsed = cpu_timer.ElapsedMillis();

    for (std::size_t i = 0; i < num_vertices(g); ++i)
    {
        rank[i] = ranks[i];
    }

    //sort the top page ranks
    RankPair<SizeT, Value> *pr_list =
        (RankPair<SizeT, Value>*)malloc(
            sizeof(RankPair<SizeT, Value>) * num_vertices(g));
    for (int i = 0; i < num_vertices(g); ++i)
    {
        pr_list[i].vertex_id = i;
        pr_list[i].page_rank = rank[i];
    }
    std::stable_sort(
        pr_list, pr_list + num_vertices(g), PRCompare<RankPair<SizeT, Value> >);

    std::vector<int> in_degree(num_vertices(g));
    std::vector<Value> refscore(num_vertices(g));

    for (int i = 0; i < num_vertices(g); ++i)
    {
        node_id[i] = pr_list[i].vertex_id;
        rank[i] = (i == src) ? 1.0 : 0;
        in_degree[i] = 0;
        refscore[i] = 0;
    }

    free(pr_list);

    int cot_size = (graph.nodes > 1000) ? 1000 : graph.nodes;

    for (int i = 0; i < cot_size; ++i)
    {
        int node = node_id[i];
        for (int j = graph.row_offsets[node];
             j < graph.row_offsets[node+1]; ++j)
        {
            VertexId edge = graph.column_indices[j];
            ++in_degree[edge];
        }
    }

    int salsa_iter = 1.0/alpha+1;
    for (int iter = 0; iter < salsa_iter; ++iter)
    {
        for (int i = 0; i < cot_size; ++i)
        {
            int node = node_id[i];
            int out_degree = graph.row_offsets[node+1]-graph.row_offsets[node];
            for (int j = graph.row_offsets[node];
                 j < graph.row_offsets[node+1]; ++j)
            {
                VertexId edge = graph.column_indices[j];
                Value val = rank[node]/ (out_degree > 0 ? out_degree : 1.0);
                refscore[edge] += val;
            }
        }
        for (int i = 0; i < cot_size; ++i)
        {
            rank[node_id[i]] = 0;
        }

        for (int i = 0; i < cot_size; ++i)
        {
            int node = node_id[i];
            rank[node] += (node == src) ? alpha : 0;
            for (int j = graph.row_offsets[node];
                 j < graph.row_offsets[node+1]; ++j)
            {
                VertexId edge = graph.column_indices[j];
                Value val = (1-alpha)*refscore[edge]/in_degree[edge];
                rank[node] += val;
            }
        }

        for (int i = 0; i < cot_size; ++i)
        {
            if (iter+1<salsa_iter) refscore[node_id[i]] = 0;
        }
    }

    //sort the top page ranks
    RankPair<SizeT, Value> *final_list =
        (RankPair<SizeT, Value>*)malloc(
            sizeof(RankPair<SizeT, Value>) * num_vertices(g));
    for (int i = 0; i < num_vertices(g); ++i)
    {
        final_list[i].vertex_id = node_id[i];
        final_list[i].page_rank = refscore[i];
    }
    std::stable_sort(
        final_list, final_list + num_vertices(g),
        PRCompare<RankPair<SizeT, Value> >);

    for (int i = 0; i < num_vertices(g); ++i)
    {
        node_id[i] = final_list[i].vertex_id;
        rank[i] = final_list[i].page_rank;
    }

    free(final_list);

    printf("CPU Who-To-Follow finished in %lf msec.\n", elapsed);
}

/**
 * @brief Run HITS tests
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 * @tparam INSTRUMENT
 *
 * @param[in] graph Reference to the CSR graph we process on
 * @param[in] src Source node ID for WTF algorithm
 * @param[in] delta Delta value for computing WTF, usually set to .85
 * @param[in] alpha Parameter to adjust iteration number
 * @param[in] error Error threshold value
 * @param[in] max_iter Max iteration for WTF computing
 * @param[in] max_grid_size Maximum CTA occupancy
 * @param[in] num_gpus Number of GPUs
 * @param[in] context CudaContext for moderngpu to use
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

    typedef WTFProblem<
        VertexId,
        SizeT,
        Value> Problem;

    Csr<VertexId, Value, SizeT>
                 *csr                 = info->csr_ptr;
    VertexId      src                   = info->info["source_vertex"].get_int64();
    int           max_grid_size         = info->info["max_grid_size"].get_int();
    int           num_gpus              = info->info["num_gpus"].get_int();
    bool          quick_mode            = info->info["quick_mode"].get_bool();
    bool          quiet_mode            = info->info["quiet_mode"].get_bool();
    bool          stream_from_host      = info->info["stream_from_host"].get_bool();
    Value         alpha                 = info->info["alpha"].get_real();
    Value         delta                 = info->info["delta"].get_real();
    Value         error                 = info->info["error"].get_real();
    SizeT         max_iter              = info->info["max_iteration"].get_int();
    ContextPtr    *context              = (ContextPtr*)info->context;

    json_spirit::mArray device_list = info->info["device_list"].get_array();
    int* gpu_idx = new int[num_gpus];
    for (int i = 0; i < num_gpus; i++) gpu_idx[i] = device_list[i].get_int();



    // Allocate host-side label array (for both reference and gpu-computed results)
    Value    *reference_rank    = (Value*)malloc(sizeof(Value) * csr->nodes);
    Value    *h_rank            = (Value*)malloc(sizeof(Value) * csr->nodes);
    VertexId *h_node_id         = (VertexId*)malloc(sizeof(VertexId) * csr->nodes);
    VertexId *reference_node_id = (VertexId*)malloc(sizeof(VertexId) * csr->nodes);
    Value    *reference_check   = (quick_mode) ? NULL : reference_rank;

    // Allocate WTF enactor map
    WTFEnactor<Problem, INSTRUMENT, DEBUG, SIZE_CHECK> wtf_enactor(gpu_idx);
    // Allocate problem on GPU
    Problem *problem = new Problem;
    util::GRError(problem->Init(
                      stream_from_host,
                      *csr,
                      num_gpus),
                  "Problem WTF Initialization Failed", __FILE__, __LINE__);

    // Perform WTF
    GpuTimer gpu_timer;

    util::GRError(
        problem->Reset(
            src, delta, alpha, error, wtf_enactor.GetFrontierType()),
        "pr Problem Data Reset Failed", __FILE__, __LINE__);
    gpu_timer.Start();
    util::GRError(
        wtf_enactor.template Enact<Problem>(
            *context, src, alpha, problem, max_iter, max_grid_size),
        "HITS Problem Enact Failed", __FILE__, __LINE__);
    gpu_timer.Stop();

    float elapsed = gpu_timer.ElapsedMillis();

    // Copy out results
    util::GRError(
        problem->Extract(h_rank, h_node_id),
        "HITS Problem Data Extraction Failed", __FILE__, __LINE__);

    float total_pr = 0;
    for (int i = 0; i < csr->nodes; ++i)
    {
        total_pr += h_rank[i];
    }

    //
    // Compute reference CPU HITS solution for source-distance
    //
    if (reference_check != NULL && total_pr > 0)
    {
        if (!quiet_mode) printf("compute ref value\n");
        SimpleReferenceWTF(
            *csr,
            src,
            reference_node_id,
            reference_check,
            delta,
            alpha,
            max_iter);
        if (!quiet_mode) printf("\n");
    }

    // Verify the result
    if (reference_check != NULL && total_pr > 0)
    {
        if (!quiet_mode) printf("Validity: ");
        CompareResults(h_rank, reference_check, csr->nodes, true);
    }

    if (!quiet_mode) {
        printf("\nGPU result.");
        DisplaySolution(h_node_id, h_rank, csr->nodes);
    }

    info->ComputeCommonStats(wtf_enactor.enactor_stats.GetPointer(), elapsed);

    if (!quiet_mode)
        info->DisplayStats();

    info->CollectInfo();

    // Cleanup
    if (problem) delete problem;
    if (reference_check) free(reference_check);
    if (h_rank) free(h_rank);

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
    if (info->info["size_check"].get_bool()) RunTests
        <VertexId, Value, SizeT, INSTRUMENT, DEBUG,
        true > (info);
   else RunTests
        <VertexId, Value, SizeT, INSTRUMENT, DEBUG,
        false> (info);
}

template <
    typename    VertexId,
    typename    Value,
    typename    SizeT,
    bool        INSTRUMENT>
void RunTests_debug(Info<VertexId, Value, SizeT> *info)
{
    if (info->info["debug_mode"].get_bool()) RunTests_size_check
        <VertexId, Value, SizeT, INSTRUMENT,
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
    if (info->info["instrument"].get_bool()) RunTests_debug
        <VertexId, Value, SizeT,
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
    if ((argc < 2) || (args.CheckCmdLineFlag("help")))
    {
        Usage();
        return 1;
    }

    //
    // Construct graph and perform search(es)
    //
    typedef int VertexId;                   // Use as the node identifier
    typedef float Value;                    // Use as the value type
    typedef int SizeT;                      // Use as the graph size type
    Csr<VertexId, Value, SizeT> csr(false); // default for stream_from_host
    Info<VertexId, Value, SizeT> *info = new Info<VertexId, Value, SizeT>;

    info->info["undirected"] = args.CheckCmdLineFlag("undirected");

    info->Init("WTF", args, csr);
    RunTests_instrumented<VertexId, Value, SizeT>(info);
    
    return 0;
}
