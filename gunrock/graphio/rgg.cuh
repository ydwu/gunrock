// ----------------------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.

/**
 * @file
 * rgg.cuh
 *
 * @brief RGG Graph Construction Routines
 */

#pragma once

#include <math.h>
#include <stdio.h>
#include <omp.h>
#include <time.h>
#include <list>
#include <gunrock/graphio/utils.cuh>
#include <gunrock/util/sort_omp.cuh>

namespace gunrock {
namespace graphio {

template <typename T>
inline T SqrtSum(T x, T y)
{
    return sqrt(x*x + y*y);
}

template <typename T>
T P2PDistance(T co_x0, T co_y0, T co_x1, T co_y1)
{
    return SqrtSum(co_x0 - co_x1, co_y0 - co_y1);
}

class RggPoint {
public:
    double x, y;
    long long node;

    RggPoint() {}
    RggPoint(double x, double y, long long node) {this->x = x; this->y = y; this->node = node;}
};

//inline bool operator< (const RggPoint& lhs, const RggPoint& rhs)
template <typename Point>
bool XFirstPointCompare (
    Point lhs,
    Point rhs)
{
    if (lhs.x < rhs.x) return true;
    if (lhs.x > rhs.x) return false;
    if (lhs.y < rhs.y) return true;
    return false;
}

template <typename T>
bool PureTwoFactor(T x)
{
    if (x<3) return true;
    while (x > 0)
    {
        if ((x%2) != 0) return false;
        x /= 2;
    }
    return true;
}

template <bool WITH_VALUES, typename VertexId, typename Value, typename SizeT>
int BuildRggGraph(
    SizeT nodes,
    Csr<VertexId, Value, SizeT> &graph,
    double threshold  = -1,
    bool   undirected = true,
    double value_multipiler = 1,
    double value_min        = 1)
{
    typedef Coo<VertexId, Value> EdgeTupleType;

    if (nodes < 0)
    {
        fprintf(stderr, "Invalid graph size: nodes = %lld\n", (long long)nodes);
        return -1;
    }

    //double   *co_x          = new double[nodes];
    //double   *co_y          = new double[nodes];
    int       reserved_size = 50;
    RggPoint *points        = new RggPoint[nodes+1];
    SizeT    *row_offsets   = new SizeT[nodes+1];
    VertexId *col_index_    = new VertexId[reserved_size * nodes];
    Value    *values_       = WITH_VALUES ? new Value[reserved_size * nodes] : NULL;
    SizeT    *offsets       = NULL;
    if (threshold < 0) 
              threshold     = 0.55 * sqrt(log(nodes)/nodes);
    SizeT     edges         = 0;
    long long row_length    = 1.0 / threshold + 1;
    VertexId **blocks       = new VertexId* [row_length * row_length + 1];
    SizeT    *block_size    = new SizeT     [row_length * row_length + 1];
    SizeT    *block_length  = new SizeT     [row_length * row_length + 1];
    VertexId *t_array       = NULL;
    VertexId *block         = NULL;
    EdgeTupleType *coo      = NULL;
    long long reserved_factor2 = 8;
    long long initial_length   = reserved_factor2 * nodes / row_length / row_length;

    if (initial_length <4) initial_length = 4;
    for (SizeT i=0; i< row_length * row_length +1; i++)
    {
        block_size  [i] = initial_length;
        block_length[i] = 0;
        blocks      [i] = new VertexId[block_size[i]];
    }
    //printf("row_length = %lld\n", row_length);
    //printf("undirected = %s\n", undirected ? "true" : "false");

    #pragma omp parallel
    {
        struct drand48_data rand_data;
        int thread_num      = omp_get_thread_num();
        int num_threads     = omp_get_num_threads();
        SizeT node_start    = (long long)(nodes) * thread_num / num_threads;
        SizeT node_end      = (long long)(nodes) * (thread_num + 1) / num_threads;
        unsigned int seed   = time(NULL) + 805 * thread_num;
        srand48_r(seed, &rand_data);
        #pragma omp single
            offsets         = new SizeT[num_threads+1];

        for (VertexId node = node_start; node < node_end; node++)
        {
            double t_value;
            drand48_r(&rand_data, &t_value); 
            points[node].x = t_value; 
            //co_x[node] = t_value;
            drand48_r(&rand_data, &t_value); 
            points[node].y = t_value; 
            //co_y[node] = t_value;
            points[node].node = node;
        }

        #pragma omp barrier
        #pragma omp single
        {
            std::stable_sort(points, points+nodes, XFirstPointCompare<RggPoint>);
        }

        #pragma omp single
        //for (VertexId node = node_start; node < node_end; node++)
        for (VertexId node = 0; node < nodes; node++)
        {
            double co_x0 = points[node].x; //co_x[node];
            double co_y0 = points[node].y; //co_y[node];
            //RggPoint point(co_x0, co_y0, node);
            SizeT x_index = co_x0 / threshold;
            SizeT y_index = co_y0 / threshold;
            SizeT block_index = x_index * row_length + y_index;

            //blocks[SizeT(co_x0 / threshold) * row_length + SizeT(co_y0 / threshold)].push_back(node);
            //#pragma atomic
            {
                SizeT current_length = block_length[block_index];
                //if (PureTwoFactor(current_size))
                if (current_length == block_size[block_index])
                {
                    if (current_length != 0)
                    {
                        t_array = blocks[block_index];
                        block   = new VertexId[current_length * 2+1];
                        //printf("Expand %d : %d -> %d\n", block_index, current_length, current_length * 2 +1); fflush(stdout);
                        for (SizeT i=0; i<current_length; i++)
                            block[i] = t_array[i];
                        delete[] t_array; t_array = NULL;
                        blocks       [block_index] = block;
                        block_length [block_index] = current_length * 2 +1;
                    } else {
                        blocks[block_index] = new VertexId[1+1];
                    }
                }
                blocks[block_index][current_length] = node;
                //printf("blocks[%d][%d] <- %d\n", block_index, current_size, node); fflush(stdout);
                block_length[block_index] = current_length +1;
            }
        }

        //struct drand48_data rand_data;
        //int thread_num      = omp_get_thread_num();
        //int num_threads     = omp_get_num_threads();
        //SizeT node_start    = (long long)(nodes) * thread_num / num_threads;
        //SizeT node_end      = (long long)(nodes) * (thread_num + 1) / num_threads;
        //unsigned int seed   = time(NULL) + 805 * thread_num;
        SizeT counter       = 0;
        VertexId *col_index = col_index_ + reserved_size * node_start;
        Value   *values     = WITH_VALUES ? values_ + reserved_size * node_start : NULL;
        //srand48_r(seed, &rand_data);

        for (VertexId node = node_start; node < node_end; node++)
        {
            row_offsets[node] = counter;
            double co_x0 = points[node].x; //co_x[node];
            double co_y0 = points[node].y; //co_y[node];
            //RggPoint point_l, point_r;
            //point_l.x = co_x0 - threshold;
            //point_l.y = co_y0 - threshold;
            //point_r.x = co_x0 + threshold;
            //point_r.y = co_y0 + threshold;
            //SizeT pos_l = util::bsearch(points, 0, nodes-1, point_l, XFirstPointCompare<RggPoint>);
            //SizeT pos_r = util::bsearch(points, 0, nodes-1, point_r, XFirstPointCompare<RggPoint>);
            SizeT x_index = co_x0 / threshold;
            SizeT y_index = co_y0 / threshold;
 
            for (SizeT x1 = x_index-2; x1 <= x_index+2; x1++)
            for (SizeT y1 = y_index-2; y1 <= y_index+2; y1++)
            // for (SizeT x1 = 0; x1 < row_length; x1++)
            // for (SizeT y1 = 0; y1 < row_length; y1++)
            {
                //if (block_index <0 || block_index >= row_length * row_length)
                if (x1 < 0 || y1 < 0 || x1 >= row_length || y1 >= row_length)
                    continue;

                SizeT block_index = x1*row_length + y1;
                //std::list<long long>* block = &(blocks[block_index]);
                VertexId *block = blocks[block_index];
                //(*block)::iterator it;
                //it =  block->begin();
                //for (std::list<long long>::iterator it = block->begin(); it != block->end(); it++)
                for (SizeT i = 0; i< block_length[block_index]; i++)
                {
                    //VertexId peer  = points[pos].node;
                    //VertexId peer = *it;
                    VertexId peer = block[i];
                    //if (node == peer) continue;
                    if (node >= peer) continue;
                    double   co_x1 = points[peer].x;//co_x[peer];
                    double   co_y1 = points[peer].y;//co_y[peer];
                    double   dis_x = co_x0 - co_x1;
                    double   dis_y = co_y0 - co_y1;
                    //if (fabs(dis_x) + fabs(dis_y) > threshold) continue;
                    if (fabs(dis_x) > threshold || fabs(dis_y) > threshold) continue;
                    double   dis   = SqrtSum(dis_x, dis_y);
                    if (dis > threshold) continue;
                    //if (!undirected)
                    //{
                    //    double rand_v;
                    //    drand48_r(&rand_data, &rand_v);
                    //    if (rand_v > 0.5) continue;
                    //}
                    
                    col_index[counter] = peer;
                    //if (WITH_VALUES) values[counter] = dis * value_multipiler;
                    if (WITH_VALUES) 
                    {
                        double t_value;
                        drand48_r(&rand_data, &t_value);
                        values[counter] = t_value * value_multipiler + value_min;
                    }
                    counter++;
                }
            }
        }
        offsets[thread_num+1] = counter;

        #pragma omp barrier
        #pragma omp single
        {
            offsets[0] = 0;
            for (int i=0; i<num_threads; i++)
                offsets[i+1] += offsets[i];
            //graph.template FromScratch<WITH_VALUES, false>(nodes, offsets[num_threads]);
            edges = offsets[num_threads] * (undirected ? 2 : 1);
            coo = (EdgeTupleType*) malloc (sizeof(EdgeTupleType) * edges);
        }
        
        /*memcpy(graph.column_indices + offsets[thread_num], col_index, sizeof(VertexId) * counter);
        if (WITH_VALUES) memcpy(graph.edge_values + offsets[thread_num], values, sizeof(VertexId) * counter);
        SizeT offset = offsets[thread_num];
        for (VertexId node = node_start; node < node_end; node++)
            graph.row_offsets[node] = row_offsets[node] + offset;*/
        SizeT offset = offsets[thread_num] * (undirected ? 2 : 1);
        for (VertexId node = node_start; node < node_end; node++)
        {
            SizeT end_edge = (node != node_end-1 ? row_offsets[node+1] : counter );
            for (SizeT edge = row_offsets[node]; edge < end_edge; edge++)
            {
                VertexId peer = col_index[edge];
                if (undirected)
                {
                    EdgeTupleType *coo_p = coo + offset + edge*2;
                    coo_p -> row = node;
                    coo_p -> col = peer;
                    coo_p -> val = WITH_VALUES ? values[edge] : 1;
                    coo_p = coo_p + 1;
                    coo_p -> row = peer;
                    coo_p -> col = node;
                    coo_p -> val = WITH_VALUES ? values[edge] : 1;
                } else {
                    EdgeTupleType *coo_p = coo + offset + edge;
                    //double rand_v;
                    //drand48_r(&rand_data, &rand_v);
                    //if (rand_v > 0.5) 
                    //{
                        coo_p -> row = node; 
                        coo_p -> col = peer;
                    //} else {
                    //    coo_p -> row = peer; 
                    //    coo_p -> col = node;
                    //}
                    coo_p -> val = WITH_VALUES ? values[edge] : 1;
                }
            }
        }

        col_index = NULL;
        values    = NULL;
    }
    //graph.row_offsets[nodes] = graph.edges;

    SizeT counter = 0;
    for (SizeT i=0;  i < row_length * row_length; i++)
    if (block_size[i] != 0)
    {
        counter += block_length[i];
        delete[] blocks[i]; blocks[i] = NULL;
    }
    //printf("counter = %lld\n", (long long) counter);

    char *out_file = NULL;
    graph.template FromCoo<WITH_VALUES, EdgeTupleType>(
        out_file, coo, nodes, edges);

    //delete[] co_x       ; co_x        = NULL;
    //delete[] co_y       ; co_y        = NULL;
    delete[] row_offsets; row_offsets = NULL;
    delete[] offsets    ; offsets     = NULL;
    delete[] points     ; points      = NULL;
    delete[] blocks     ; blocks      = NULL;
    delete[] block_size ; block_size  = NULL;
    delete[] block_length; block_length = NULL;
    delete[] col_index_ ; col_index_  = NULL;
    if (WITH_VALUES) {delete[] values_; values_ = NULL;}
    free(coo); coo=NULL;

    return 0;
}

} // namespace graphio
} // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
          