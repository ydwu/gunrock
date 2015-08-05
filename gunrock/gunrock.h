// ----------------------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------------------

/**
 * @file gunrock.h
 *
 * @brief Main library header file. Defines public C interface.
 * The Gunrock public interface is a C-only interface to enable linking
 * with code written in other languages. While the internals of Gunrock
 * are not limited to C.
 */

#include <stdlib.h>
#include <stdbool.h>

/**
 * @brief VertexId data type enumerators.
 */
enum VtxIdType
{
    VTXID_INT,  // Integer
};

/**
 * @brief SizeT data type enumerators.
 */
enum SizeTType
{
    SIZET_INT,  // Unsigned integer
};

/**
 * @brief Value data type enumerators.
 */
enum ValueType
{
    VALUE_INT,    // Integer
    VALUE_UINT,   // Unsigned integer
    VALUE_FLOAT,  // Float
};

/**
 * @brief Data type configuration used to specify data types.
 */
struct GRTypes
{
    enum VtxIdType VTXID_TYPE;  // VertexId data type
    enum SizeTType SIZET_TYPE;  // SizeT data type
    enum ValueType VALUE_TYPE;  // Value data type
};

/**
 * @brief GunrockGraph as a standard graph interface.
 */
struct GRGraph
{
    size_t  num_nodes;  // Number of nodes in graph
    size_t  num_edges;  // Number of edges in graph
    void *row_offsets;  // CSR row offsets
    void *col_indices;  // CSR column indices
    void *col_offsets;  // CSC column offsets
    void *row_indices;  // CSC row indices
    void *edge_values;  // Associated values per edge

    void *node_value1;  // Associated values per node
    void *edge_value1;  // Associated values per edge
    void *node_value2;  // Associated values per node
    void *edge_value2;  // Associated values per edge
    void *aggregation;  // Global reduced aggregation
};

/**
 * @brief Source Vertex Mode enumerators.
 */
enum SrcMode
{
    manually,        // Manually set up source node
    randomize,       // Random generate source node
    largest_degree,  // Largest-degree node as source
};

/**
 * @brief arguments configuration used to specify arguments.
 */
struct GRSetup
{
    bool               quiet;  // Whether to print out to STDOUT
    bool   mark_predecessors;  // Whether to mark predecessor or not
    bool  enable_idempotence;  // Whether or not to enable idempotent
    int        source_vertex;  // Source node define where to start
    int         delta_factor;  // SSSP delta-factor parameter
    int*         device_list;  // Setting which device(s) to use
    unsigned int num_devices;  // Number of devices for computation
    unsigned int   max_iters;  // Maximum number of iterations allowed
    unsigned int   top_nodes;  // K value for top k / PageRank problem
    float     pagerank_delta;  // PageRank specific value
    float     pagerank_error;  // PageRank specific value
    float   max_queue_sizing;  // Setting frontier queue size
    int       traversal_mode;  // Traversal mode: 0 for LB, 1 TWC
    enum SrcMode source_mode;  // Source mode rand/largest_degree
};

/**
 * @brief Initialization function for GRSetup.
 * \return Initialized configurations object.
 */
#ifdef __clang__
// http://clang.llvm.org/compatibility.html#inline
static
#endif
inline struct GRSetup InitSetup()
{
    struct GRSetup configurations;
    configurations.quiet = true;
    configurations.mark_predecessors = true;
    configurations.enable_idempotence = false;
    configurations.source_vertex = 0;
    configurations.delta_factor = 32;
    configurations.num_devices = 1;
    configurations.max_iters = 50;
    configurations.top_nodes = 10;
    configurations.pagerank_delta = 0.85f;
    configurations.pagerank_error = 0.01f;
    configurations.max_queue_sizing = 1.0;
    configurations.traversal_mode = 0;
    configurations.source_mode = manually;
    int* gpu_idx = (int*)malloc(sizeof(int)); gpu_idx[0] = 0;
    configurations.device_list = gpu_idx;
    return configurations;
}

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Breath-first search public interface.
 *
 * @param[out] grapho Output data structure contains results.
 * @param[in]  graphi Input data structure contains graph.
 * @param[in]  config Primitive-specific configurations.
 * @param[in]  data_t Primitive-specific data type setting.
 */
void gunrock_bfs(
    struct GRGraph*       grapho,   // Output graph / results
    const struct GRGraph* graphi,   // Input graph structure
    const struct GRSetup  config,   // Flag configurations
    const struct GRTypes  data_t);  // Data type Configurations

/**
 * @brief Breath-first search simple public interface.
 *
 * @param[out] Return bfs labels (depth).
 * @param[in] Input graph number of nodes.
 * @param[in] Input graph number of edges.
 * @param[in] Input graph row_offsets.
 * @param[in] Input graph col_indices.
 * @param[in] Source node to start.
 */
void bfs(
    int*       bfs_label,    // Return label (depth) per node
    const int  num_nodes,    // Input graph number of nodes
    const int  num_edges,    // Input graph number of edges
    const int* row_offsets,  // Input graph row_offsets
    const int* col_indices,  // Input graph col_indices
    const int  source);      // Source vertex to start

/**
 * @brief Betweenness centrality public interface.
 *
 * @param[out] grapho Output data structure contains results.
 * @param[in]  graphi Input data structure contains graph.
 * @param[in]  config Primitive-specific configurations.
 * @param[in]  data_t Primitive-specific data type setting.
 */
void gunrock_bc(
    struct GRGraph*       grapho,   // Output graph / results
    const struct GRGraph* graphi,   // Input graph structure
    const struct GRSetup  config,   // Flag configurations
    const struct GRTypes  data_t);  // Data type Configurations

/**
 * @brief Betweenness centrality simple public interface.
 *
 * @param[out] Return betweenness centralities.
 * @param[in] Input graph number of nodes.
 * @param[in] Input graph number of edges.
 * @param[in] Input graph row_offsets.
 * @param[in] Input graph col_indices.
 * @param[in] Source node to start.
 */
void bc(
    float*     bc_scores,    // Return centrality score per node
    const int  num_nodes,    // Input graph number of nodes
    const int  num_edges,    // Input graph number of edges
    const int* row_offsets,  // Input graph row_offsets
    const int* col_indices,  // Input graph col_indices
    const int  source);      // Source vertex to start

/**
 * @brief Connected component public interface.
 *
 * @param[out] grapho Output data structure contains results.
 * @param[in]  graphi Input data structure contains graph.
 * @param[in]  config Primitive-specific configurations.
 * @param[in]  data_t Primitive-specific data type setting.
 */
void gunrock_cc(
    struct GRGraph*       grapho,   // Output graph / results
    const struct GRGraph* graphi,   // Input graph structure
    const struct GRSetup  config,   // Flag configurations
    const struct GRTypes  data_t);  // Data type Configurations

/**
 * @brief Connected component simple public interface.
 *
 * @param[out] Return per-node component IDs.
 * @param[in] Input graph number of nodes.
 * @param[in] Input graph number of edges.
 * @param[in] Input graph row_offsets.
 * @param[in] Input graph col_indices.
 */
int cc(
    int*       component,     // Return component IDs per node
    const int  num_nodes,     // Input graph number of nodes
    const int  num_edges,     // Input graph number of edges
    const int* row_offsets,   // Input graph row_offsets
    const int* col_indices);  // Input graph col_indices

/**
 * @brief Single-source shortest path public interface.
 *
 * @param[out] grapho Output data structure contains results.
 * @param[in]  graphi Input data structure contains graph.
 * @param[in]  config Primitive-specific configurations.
 * @param[in]  data_t Primitive-specific data type setting.
 */
void gunrock_sssp(
    struct GRGraph*       grapho,   // Output graph / results
    const struct GRGraph* graphi,   // Input graph structure
    const struct GRSetup  config,   // Flag configurations
    const struct GRTypes  data_t);  // Data type Configurations

/**
 * @brief Single-source shortest path simple public interface.
 *
 * @param[out] Return shortest distances.
 * @param[in] Input graph number of nodes.
 * @param[in] Input graph number of edges.
 * @param[in] Input graph row_offsets.
 * @param[in] Input graph col_indices.
 * @param[in] Input graph edge weight.
 * @param[in] Source node to start.
 */
void sssp(
    unsigned int*       distances,    // Return shortest distances
    const int           num_nodes,    // Input graph number of nodes
    const int           num_edges,    // Input graph number of edges
    const int*          row_offsets,  // Input graph row_offsets
    const int*          col_indices,  // Input graph col_indices
    const unsigned int* edge_values,  // Input graph edge weight
    const int           source);      // Source node to start

/**
 * @brief PageRank public interface.
 *
 * @param[out] grapho Output data structure contains results.
 * @param[in]  graphi Input data structure contains graph.
 * @param[in]  config Primitive-specific configurations.
 * @param[in]  data_t Primitive-specific data type setting.
 */
void gunrock_pagerank(
    struct GRGraph*       grapho,   // Output graph / results
    const struct GRGraph* graphi,   // Input graph structure
    const struct GRSetup  config,   // Flag configurations
    const struct GRTypes  data_t);  // Data type Configurations

/**
 * @brief PageRank simple public interface.
 *
 * @param[out] Return top-ranked vertex IDs.
 * @param[out] Return top-ranked PageRank scores.
 * @param[in] Input graph number of nodes.
 * @param[in] Input graph number of edges.
 * @param[in] Input graph row_offsets.
 * @param[in] Input graph col_indices.
 */
void pagerank(
    int*       node_ids,      // Return top-ranked vertex IDs
    float*     pagerank,      // Return top-ranked PageRank scores
    const int  num_nodes,     // Input graph number of nodes
    const int  num_edges,     // Input graph number of edges
    const int* row_offsets,   // Input graph row_offsets
    const int* col_indices);  // Input graph col_indices

// TODO Add other primitives

#ifdef __cplusplus
}
#endif

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
