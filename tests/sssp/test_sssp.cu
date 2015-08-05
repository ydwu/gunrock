// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * test_sssp.cu
 *
 * @brief Simple test driver program for single source shorest path.
 */

#include <stdio.h>
#include <string>
#include <deque>
#include <vector>
#include <iostream>

// Utilities and correctness-checking
#include <gunrock/util/test_utils.cuh>

// SSSP includes
#include <gunrock/app/sssp/sssp_enactor.cuh>
#include <gunrock/app/sssp/sssp_problem.cuh>
#include <gunrock/app/sssp/sssp_functor.cuh>

// Operator includes
#include <gunrock/oprtr/advance/kernel.cuh>
#include <gunrock/oprtr/filter/kernel.cuh>
#include <gunrock/priority_queue/kernel.cuh>

#include <moderngpu.cuh>

// Boost includes for CPU dijkstra SSSP reference algorithms
#include <boost/config.hpp>
#include <boost/graph/graph_traits.hpp>
#include <boost/graph/adjacency_list.hpp>
#include <boost/graph/dijkstra_shortest_paths.hpp>
#include <boost/property_map/property_map.hpp>

using namespace gunrock;
using namespace gunrock::app;
using namespace gunrock::util;
using namespace gunrock::oprtr;
using namespace gunrock::app::sssp;

/******************************************************************************
 * Housekeeping Routines
 ******************************************************************************/
void Usage()
{
    printf(
        " test_sssp <graph type> <graph type args> [--device=<device_index>]\n"
        " [--undirected] [--instrumented] [--src=<source index>] [--quick=<0|1>]\n"
        " [--mark-pred] [--queue-sizing=<scale factor>] [--traversal-mode=<0|1>]\n"
        " [--in-sizing=<in/out queue scale factor>] [--disable-size-check]\n"
        " [--grid-size=<grid size>] [partition_method=<random|biasrandom|clustered|metis>]\n"
        " [--v] [--iteration-num=<num>]\n"
        "\n"
        "Graph types and args:\n"
        "  market [<file>]\n"
        "    Reads a Matrix-Market coordinate-formatted graph of directed / undirected\n"
        "    edges from stdin (or from the optionally-specified file).\n"
        "  --device=<device_index>   Set GPU device for running the test. [Default: 0].\n"
        "  --undirected              Treat the graph as undirected (symmetric).\n"
        "  --instrumented            Keep kernels statics [Default: Disable].\n"
        "                            total_queued, search_depth and barrier duty\n"
        "                            (a relative indicator of load imbalance.)\n"
        "  --src=<source vertex id>  Begins SSSP from the source [Default: 0].\n"
        "                            If randomize: from a random source vertex.\n"
        "                            If largestdegree: from largest degree vertex.\n"
        "  --quick=<0 or 1>          Skip the CPU validation: 1, or not: 0 [Default: 1].\n"
        "  --mark-pred               Keep both label info and predecessor info.\n"
        "  --queue-sizing=<factor>   Allocates a frontier queue sized at:\n"
        "                            (graph-edges * <scale factor>) [Default: 1.0].\n"
        "  --v                       Print verbose per iteration debug info.\n"
        "  --iteration-num=<number>  Number of runs to perform the test [Default: 1].\n"
        "  --traversal-mode=<0 or 1> Set traversal strategy, 0 for Load-Balanced,\n"
        "                            1 for Dynamic-Cooperative [Default: dynamic\n"
        "                            determine based on average degree].\n"
    );
}

/**
 * @brief Displays the SSSP result (i.e., distance from source)
 *
 * @tparam VertexId
 * @tparam SizeT
 *
 * @param[in] source_path Search depth from the source for each node.
 * @param[in] num_nodes Number of nodes in the graph.
 */
template<typename VertexId, typename SizeT>
void DisplaySolution (VertexId *source_path, SizeT num_nodes)
{
    if (num_nodes > 40) num_nodes = 40;

    printf("[");
    for (VertexId i = 0; i < num_nodes; ++i)
    {
        PrintValue(i);
        printf(":");
        PrintValue(source_path[i]);
        printf(" ");
    }
    printf("]\n");
}

/******************************************************************************
 * SSSP Testing Routines
 *****************************************************************************/

/**
 * @brief A simple CPU-based reference SSSP ranking implementation.
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 * @tparam MARK_PREDECESSORS
 *
 * @param[in] graph Reference to the CSR graph we process on
 * @param[in] node_values Host-side vector to store CPU computed labels for each node
 * @param[in] node_preds Host-side vector to store CPU computed predecessors for each node
 * @param[in] src Source node where SSSP starts
 */
template <
    typename VertexId,
    typename Value,
    typename SizeT,
    bool     MARK_PREDECESSORS >
void SimpleReferenceSssp(
    const Csr<VertexId, Value, SizeT> &graph,
    Value                             *node_values,
    VertexId                          *node_preds,
    VertexId                          src,
    bool                              quiet)
{
    using namespace boost;

    // Prepare Boost Datatype and Data structure
    typedef adjacency_list<vecS, vecS, directedS, no_property,
            property <edge_weight_t, unsigned int> > Graph;

    typedef graph_traits<Graph>::vertex_descriptor vertex_descriptor;
    typedef graph_traits<Graph>::edge_descriptor edge_descriptor;

    typedef std::pair<VertexId, VertexId> Edge;

    Edge   *edges = ( Edge*)malloc(sizeof( Edge) * graph.edges);
    Value *weight = (Value*)malloc(sizeof(Value) * graph.edges);

    for (int i = 0; i < graph.nodes; ++i)
    {
        for (int j = graph.row_offsets[i]; j < graph.row_offsets[i + 1]; ++j)
        {
            edges[j] = Edge(i, graph.column_indices[j]);
            weight[j] = graph.edge_values[j];
        }
    }

    Graph g(edges, edges + graph.edges, weight, graph.nodes);

    std::vector<Value> d(graph.nodes);
    std::vector<vertex_descriptor> p(graph.nodes);
    vertex_descriptor s = vertex(src, g);

    property_map<Graph, vertex_index_t>::type indexmap = get(vertex_index, g);

    //
    // Perform SSSP
    //

    CpuTimer cpu_timer;
    cpu_timer.Start();

    if (MARK_PREDECESSORS)
    {
        dijkstra_shortest_paths(g, s,
                                predecessor_map(boost::make_iterator_property_map(
                                        p.begin(), get(boost::vertex_index, g))).distance_map(
                                    boost::make_iterator_property_map(
                                        d.begin(), get(boost::vertex_index, g))));
    }
    else
    {
        dijkstra_shortest_paths(g, s,
                                distance_map(boost::make_iterator_property_map(
                                        d.begin(), get(boost::vertex_index, g))));
    }
    cpu_timer.Stop();
    float elapsed = cpu_timer.ElapsedMillis();

    if (!quiet) { printf("CPU SSSP finished in %lf msec.\n", elapsed); }

    Coo<Value, Value>* sort_dist = NULL;
    Coo<VertexId, VertexId>* sort_pred = NULL;
    sort_dist = (Coo<Value, Value>*)malloc(
                    sizeof(Coo<Value, Value>) * graph.nodes);
    if (MARK_PREDECESSORS)
    {
        sort_pred = (Coo<VertexId, VertexId>*)malloc(
                        sizeof(Coo<VertexId, VertexId>) * graph.nodes);
    }
    graph_traits < Graph >::vertex_iterator vi, vend;
    for (tie(vi, vend) = vertices(g); vi != vend; ++vi)
    {
        sort_dist[(*vi)].row = (*vi);
        sort_dist[(*vi)].col = d[(*vi)];
    }
    std::stable_sort(
        sort_dist, sort_dist + graph.nodes,
        RowFirstTupleCompare<Coo<Value, Value> >);

    if (MARK_PREDECESSORS)
    {
        for (tie(vi, vend) = vertices(g); vi != vend; ++vi)
        {
            sort_pred[(*vi)].row = (*vi);
            sort_pred[(*vi)].col = p[(*vi)];
        }
        std::stable_sort(
            sort_pred, sort_pred + graph.nodes,
            RowFirstTupleCompare< Coo<VertexId, VertexId> >);
    }

    for (int i = 0; i < graph.nodes; ++i)
    {
        node_values[i] = sort_dist[i].col;
    }
    if (MARK_PREDECESSORS)
    {
        for (int i = 0; i < graph.nodes; ++i)
        {
            node_preds[i] = sort_pred[i].col;
        }
    }
    if (sort_dist) free(sort_dist);
    if (sort_pred) free(sort_pred);
}


/**
 * @brief Run SSSP tests
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 * @tparam INSTRUMENT
 * @tparam MARK_PREDECESSORS
 *
 * @param[in] parameter Pointer to test parameter settings
 */
template <
    typename VertexId,
    typename Value,
    typename SizeT,
    bool INSTRUMENT,
    bool DEBUG,
    bool SIZE_CHECK,
    bool MARK_PREDECESSORS >
void RunTests(Info<VertexId, Value, SizeT> *info)
{
    typedef SSSPProblem < VertexId,
            SizeT,
            Value,
            MARK_PREDECESSORS > Problem;

    typedef SSSPEnactor < Problem,
            INSTRUMENT,
            DEBUG,
            SIZE_CHECK > Enactor;

    // parse configurations from mObject info
    Csr<VertexId, Value, SizeT> *graph = info->csr_ptr;
    VertexId src                 = info->info["source_vertex"].get_int64();
    int max_grid_size            = info->info["max_grid_size"].get_int();
    int num_gpus                 = info->info["num_gpus"].get_int();
    double max_queue_sizing      = info->info["max_queue_sizing"].get_real();
    double max_queue_sizing1     = info->info["max_queue_sizing1"].get_real();
    double max_in_sizing         = info->info["max_in_sizing"].get_real();
    std::string partition_method = info->info["partition_method"].get_str();
    double partition_factor      = info->info["partition_factor"].get_real();
    int partition_seed           = info->info["partition_seed"].get_int();
    bool quiet_mode              = info->info["quiet_mode"].get_bool();
    bool quick_mode              = info->info["quick_mode"].get_bool();
    bool stream_from_host        = info->info["stream_from_host"].get_bool();
    int traversal_mode           = info->info["traversal_mode"].get_int();
    int iterations               = info->info["num_iteration"].get_int();
    int delta_factor             = info->info["delta_factor"].get_int();

    json_spirit::mArray device_list = info->info["device_list"].get_array();
    int* gpu_idx = new int[num_gpus];
    for (int i = 0; i < num_gpus; i++) gpu_idx[i] = device_list[i].get_int();

    // TODO: remove after merge mgpu-cq
    ContextPtr   *context = (ContextPtr*)  info->context;
    cudaStream_t *streams = (cudaStream_t*)info->streams;

    // Allocate host-side array (for both reference and GPU-computed results)
    Value    *reference_labels      = new Value[graph->nodes];
    Value    *h_labels              = new Value[graph->nodes];
    Value    *reference_check_label = (quick_mode) ? NULL : reference_labels;
    VertexId *reference_preds       = MARK_PREDECESSORS ? new VertexId[graph->nodes] : NULL;
    VertexId *h_preds               = MARK_PREDECESSORS ? new VertexId[graph->nodes] : NULL;
    VertexId *reference_check_pred  = (quick_mode || !MARK_PREDECESSORS) ? NULL : reference_preds;

    size_t *org_size = new size_t[num_gpus];
    for (int gpu = 0; gpu < num_gpus; gpu++)
    {
        size_t dummy;
        cudaSetDevice(gpu_idx[gpu]);
        cudaMemGetInfo(&(org_size[gpu]), &dummy);
    }

    // Allocate SSSP enactor map
    Enactor* enactor = new Enactor(num_gpus, gpu_idx);

    // Allocate problem on GPU
    Problem *problem = new Problem;
    util::GRError(problem->Init(
                      stream_from_host,
                      graph,
                      NULL,
                      num_gpus,
                      gpu_idx,
                      partition_method,
                      streams,
                      delta_factor,
                      max_queue_sizing,
                      max_in_sizing,
                      partition_factor,
                      partition_seed),
                  "SSSP Problem Init failed", __FILE__, __LINE__);
    util::GRError(enactor->Init(
        context, problem, max_grid_size, traversal_mode),
                  "SSSP Enactor Init failed", __FILE__, __LINE__);

    // compute reference CPU SSSP solution for source-distance
    if (reference_check_label != NULL)
    {
        if (!quiet_mode) { printf("Computing reference value ...\n"); }
        SimpleReferenceSssp<VertexId, Value, SizeT, MARK_PREDECESSORS>(
            *graph,
            reference_check_label,
            reference_check_pred,
            src,
            quiet_mode);
        if (!quiet_mode) { printf("\n"); }
    }

    double elapsed = 0.0f;

    // perform SSSP
    CpuTimer cpu_timer;

    for (int iter = 0; iter < iterations; ++iter)
    {
        util::GRError(problem->Reset(
                          src, enactor->GetFrontierType(), max_queue_sizing),
                      "SSSP Problem Data Reset Failed", __FILE__, __LINE__);
        util::GRError(enactor->Reset(),
                      "SSSP Enactor Reset failed", __FILE__, __LINE__);

        if (!quiet_mode)
        {
            printf("__________________________\n"); fflush(stdout);
        }
        cpu_timer.Start();
        util::GRError(enactor->Enact(src, traversal_mode),
                      "SSSP Problem Enact Failed", __FILE__, __LINE__);
        cpu_timer.Stop();
        if (!quiet_mode)
        {
            printf("--------------------------\n"); fflush(stdout);
        }
        elapsed += cpu_timer.ElapsedMillis();
    }
    elapsed /= iterations;

    // Copy out results
    util::GRError(problem->Extract(h_labels, h_preds),
                  "SSSP Problem Data Extraction Failed", __FILE__, __LINE__);

    for (SizeT i = 0; i < graph->nodes; i++)
    {
        if (reference_check_label[i] == -1)
        {
            reference_check_label[i] = util::MaxValue<Value>();
        }
    }

    if (!quiet_mode)
    {
        // Display Solution
        printf("\nFirst 40 labels of the GPU result.\n");
        DisplaySolution(h_labels, graph->nodes);
    }
    // Verify the result
    if (reference_check_label != NULL)
    {
        if (!quiet_mode) { printf("Label Validity: "); }
        int error_num = CompareResults(
                            h_labels, reference_check_label,
                            graph->nodes, true, quiet_mode);
        if (error_num > 0)
        {
            if (!quiet_mode) { printf("%d errors occurred.\n", error_num); }
        }
        if (!quiet_mode)
        {
            printf("\nFirst 40 labels of the reference CPU result.\n");
            DisplaySolution(reference_check_label, graph->nodes);
        }
    }

    info->ComputeTraversalStats(  // compute running statistics
        enactor->enactor_stats.GetPointer(), elapsed, h_labels);

    if (!quiet_mode)
    {
        info->DisplayStats();  // display collected statistics
    }

    info->CollectInfo();  // collected all the info and put into JSON mObject

    if (!quiet_mode)
    {
        if (MARK_PREDECESSORS)
        {
            printf("\nFirst 40 preds of the GPU result.\n");
            DisplaySolution(h_preds, graph->nodes);
            if (reference_check_label != NULL)
            {
                printf("\nFirst 40 preds of the reference CPU result (could be different because the paths are not unique).\n");
                DisplaySolution(reference_check_pred, graph->nodes);
            }
        }

        printf("\n\tMemory Usage(B)\t");
        for (int gpu = 0; gpu < num_gpus; gpu++)
            if (num_gpus > 1) {if (gpu != 0) printf(" #keys%d,0\t #keys%d,1\t #ins%d,0\t #ins%d,1", gpu, gpu, gpu, gpu); else printf(" #keys%d,0\t #keys%d,1", gpu, gpu);}
            else printf(" #keys%d,0\t #keys%d,1", gpu, gpu);
        if (num_gpus > 1) printf(" #keys%d", num_gpus);
        printf("\n");
        double max_queue_sizing_[2] = {0, 0}, max_in_sizing_ = 0;
        for (int gpu = 0; gpu < num_gpus; gpu++)
        {
            size_t gpu_free, dummy;
            cudaSetDevice(gpu_idx[gpu]);
            cudaMemGetInfo(&gpu_free, &dummy);
            printf("GPU_%d\t %ld", gpu_idx[gpu], org_size[gpu] - gpu_free);
            for (int i = 0; i < num_gpus; i++)
            {
                for (int j = 0; j < 2; j++)
                {
                    SizeT x = problem->data_slices[gpu]->frontier_queues[i].keys[j].GetSize();
                    printf("\t %lld", (long long) x);
                    double factor = 1.0 * x / (num_gpus > 1 ? problem->graph_slices[gpu]->in_counter[i] : problem->graph_slices[gpu]->nodes);
                    if (factor > max_queue_sizing_[j]) max_queue_sizing_[j] = factor;
                }
                if (num_gpus > 1 && i != 0 )
                    for (int t = 0; t < 2; t++)
                    {
                        SizeT x = problem->data_slices[gpu][0].keys_in[t][i].GetSize();
                        printf("\t %lld", (long long) x);
                        double factor = 1.0 * x / problem->graph_slices[gpu]->in_counter[i];
                        if (factor > max_in_sizing_) max_in_sizing_ = factor;
                    }
            }
            if (num_gpus > 1) printf("\t %lld", (long long)(problem->data_slices[gpu]->frontier_queues[num_gpus].keys[0].GetSize()));
            printf("\n");
        }
        printf("\t queue_sizing =\t %lf \t %lf", max_queue_sizing_[0], max_queue_sizing_[1]);
        if (num_gpus > 1) printf("\t in_sizing =\t %lf", max_in_sizing_);
        printf("\n");
    }

    // Clean up
    if (org_size        ) {delete[] org_size        ; org_size         = NULL;}
    if (enactor         ) {delete   enactor         ; enactor          = NULL;}
    if (problem         ) {delete   problem         ; problem          = NULL;}
    if (reference_labels) {delete[] reference_labels; reference_labels = NULL;}
    if (h_labels        ) {delete[] h_labels        ; h_labels         = NULL;}
    if (reference_preds ) {delete[] reference_preds ; reference_preds  = NULL;}
    if (h_preds         ) {delete[] h_preds         ; h_preds          = NULL;}
}

/**
 * @brief RunTests entry
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 * @tparam INSTRUMENT
 * @tparam DEBUG
 * @tparam SIZE_CHECK
 *
 * @param[in] info Pointer to mObject info.
 */
template <
    typename    VertexId,
    typename    Value,
    typename    SizeT,
    bool        INSTRUMENT,
    bool        DEBUG,
    bool        SIZE_CHECK >
void RunTests_mark_predecessors(Info<VertexId, Value, SizeT> *info)
{
    if (info->info["mark_predecessors"].get_bool())
    {
        RunTests<VertexId, Value, SizeT, INSTRUMENT,
                 DEBUG, SIZE_CHECK, true>(info);
    }
    else
    {
        RunTests<VertexId, Value, SizeT, INSTRUMENT,
                 DEBUG, SIZE_CHECK, false>(info);
    }
}

/**
 * @brief RunTests entry
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 * @tparam INSTRUMENT
 * @tparam DEBUG
 *
 * @param[in] info Pointer to mObject info.
 */
template <
    typename      VertexId,
    typename      Value,
    typename      SizeT,
    bool          INSTRUMENT,
    bool          DEBUG >
void RunTests_size_check(Info<VertexId, Value, SizeT> *info)
{
    if (info->info["size_check"].get_bool())
    {
        RunTests_mark_predecessors<VertexId, Value, SizeT, INSTRUMENT,
                                   DEBUG,  true>(info);
    }
    else
    {
        RunTests_mark_predecessors<VertexId, Value, SizeT, INSTRUMENT,
                                   DEBUG, false>(info);
    }
}

/**
 * @brief RunTests entry
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 * @tparam INSTRUMENT
 *
 * @param[in] info Pointer to mObject info.
 */
template <
    typename    VertexId,
    typename    Value,
    typename    SizeT,
    bool        INSTRUMENT >
void RunTests_debug(Info<VertexId, Value, SizeT> *info)
{
    if (info->info["debug_mode"].get_bool())
    {
        RunTests_size_check<VertexId, Value, SizeT, INSTRUMENT,  true>(info);
    }
    else
    {
        RunTests_size_check<VertexId, Value, SizeT, INSTRUMENT, false>(info);
    }
}

/**
 * @brief RunTests entry
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 *
 * @param[in] info Pointer to mObject info.
 */
template <
    typename      VertexId,
    typename      Value,
    typename      SizeT >
void RunTests_instrumented(Info<VertexId, Value, SizeT> *info)
{
    if (info->info["instrument"].get_bool())
    {
        RunTests_debug<VertexId, Value, SizeT, true>(info);
    }
    else
    {
        RunTests_debug<VertexId, Value, SizeT, false>(info);
    }
}

/******************************************************************************
* Main
******************************************************************************/

int main(int argc, char** argv)
{
    CommandLineArgs args(argc, argv);
    int graph_args = argc - args.ParsedArgc() - 1;
    if (argc < 2 || graph_args < 1 || args.CheckCmdLineFlag("help"))
    {
        Usage();
        return 1;
    }

    typedef int VertexId;  // Use int as the vertex identifier
    typedef int Value;     // Use int as the value type
    typedef int SizeT;     // Use int as the graph size type

    Csr<VertexId, Value, SizeT> csr(false);  // graph we process on
    Info<VertexId, Value, SizeT> *info = new Info<VertexId, Value, SizeT>;

    // graph construction or generation related parameters
    info->info["undirected"] = args.CheckCmdLineFlag("undirected");
    info->info["edge_value"] = true;  // require per edge weight values

    info->Init("SSSP", args, csr);  // initialize Info structure
    RunTests_instrumented<VertexId, Value, SizeT>(info);  // run test

    return 0;
}
