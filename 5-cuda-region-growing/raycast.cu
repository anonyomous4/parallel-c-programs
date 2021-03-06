#include <stdio.h>
#include <stdlib.h>
#include <cuda.h>
#include <math.h>
#include <time.h>
#include <sys/time.h>

#include "bmp.h"

// data is 3D, total size is DATA_DIM x DATA_DIM x DATA_DIM
#define DATA_DIM 512
#define DATA_SIZE (DATA_DIM * DATA_DIM * DATA_DIM) 
#define DATA_SIZE_BYTES (sizeof(unsigned char) * DATA_SIZE)

// image is 2D, total size is IMAGE_DIM x IMAGE_DIM
#define IMAGE_DIM 512
#define IMAGE_SIZE (IMAGE_DIM * IMAGE_DIM)
#define IMAGE_SIZE_BYTES (sizeof(unsigned char) * IMAGE_SIZE)

texture<char, cudaTextureType3D, cudaReadModeNormalizedFloat> data_texture;
texture<char, cudaTextureType3D, cudaReadModeNormalizedFloat> region_texture;

void print_time(struct timeval start, struct timeval end){
    long int ms = ((end.tv_sec * 1000000 + end.tv_usec) - (start.tv_sec * 1000000 + start.tv_usec));
    double s = ms/1e6;
    printf("Time : %f s\n", s);
}
// Stack for the serial region growing
typedef struct{
    int size;
    int buffer_size;
    int3* pixels;
} stack_t;

stack_t* new_stack(){
    stack_t* stack = (stack_t*)malloc(sizeof(stack_t));
    stack->size = 0;
    stack->buffer_size = 1024;
    stack->pixels = (int3*)malloc(sizeof(int3)*1024);

    return stack;
}

void push(stack_t* stack, int3 p){
    if(stack->size == stack->buffer_size){
        stack->buffer_size *= 2;
        int3* temp = stack->pixels;
        stack->pixels = (int3*)malloc(sizeof(int3)*stack->buffer_size);
        memcpy(stack->pixels, temp, sizeof(int3)*stack->buffer_size/2);
        free(temp);

    }
    stack->pixels[stack->size] = p;
    stack->size += 1;
}

int3 pop(stack_t* stack){
    stack->size -= 1;
    return stack->pixels[stack->size];
}

// float3 utilities
__host__ __device__ float3 cross(float3 a, float3 b){
    float3 c;
    c.x = a.y*b.z - a.z*b.y;
    c.y = a.z*b.x - a.x*b.z;
    c.z = a.x*b.y - a.y*b.x;

    return c;
}

__host__ __device__ float3 normalize(float3 v){
    float l = sqrt(v.x*v.x + v.y*v.y + v.z*v.z);
    v.x /= l;
    v.y /= l;
    v.z /= l;

    return v;
}

__host__ __device__ float3 add(float3 a, float3 b){
    a.x += b.x;
    a.y += b.y;
    a.z += b.z;

    return a;
}

__host__ __device__ float3 scale(float3 a, float b){
    a.x *= b;
    a.y *= b;
    a.z *= b;

    return a;
}


// Prints CUDA device properties
void print_properties(){
    int deviceCount = 0;
    cudaGetDeviceCount(&deviceCount);
    printf("Device count: %d\n", deviceCount);

    cudaDeviceProp p;
    cudaSetDevice(0);
    cudaGetDeviceProperties (&p, 0);
    printf("Compute capability: %d.%d\n", p.major, p.minor);
    printf("Name: %s\n" , p.name);
    printf("\n\n");
}


// Fills data with values
unsigned char func(int x, int y, int z){
    unsigned char value = rand() % 20;

    int x1 = 300;
    int y1 = 400;
    int z1 = 100;
    float dist = sqrt((x-x1)*(x-x1) + (y-y1)*(y-y1) + (z-z1)*(z-z1));

    if(dist < 100){
        value  = 30;
    }

    x1 = 100;
    y1 = 200;
    z1 = 400;
    dist = sqrt((x-x1)*(x-x1) + (y-y1)*(y-y1) + (z-z1)*(z-z1));



    if(dist < 50){
        value = 50;
    }

    if(x > 200 && x < 300 && y > 300 && y < 500 && z > 200 && z < 300){
        value = 45;
    }
    if(x > 0 && x < 100 && y > 250 && y < 400 && z > 250 && z < 400){
        value =35;
    }
    return value;
}

unsigned char* create_data(){
    unsigned char* data = (unsigned char*)malloc(sizeof(unsigned char) * DATA_DIM*DATA_DIM*DATA_DIM);

    for(int i = 0; i < DATA_DIM; i++){
        for(int j = 0; j < DATA_DIM; j++){
            for(int k = 0; k < DATA_DIM; k++){
                data[i*DATA_DIM*DATA_DIM + j*DATA_DIM+ k]= func(k,j,i);
            }
        }
    }

    return data;
}

// Checks if position is inside the volume (float3 and int3 versions)
__host__ __device__ int inside(float3 pos){
    int x = (pos.x >= 0 && pos.x < DATA_DIM-1);
    int y = (pos.y >= 0 && pos.y < DATA_DIM-1);
    int z = (pos.z >= 0 && pos.z < DATA_DIM-1);

    return x && y && z;
}

__host__ __device__ int inside(int3 pos){
    int x = (pos.x >= 0 && pos.x < DATA_DIM);
    int y = (pos.y >= 0 && pos.y < DATA_DIM);
    int z = (pos.z >= 0 && pos.z < DATA_DIM);

    return x && y && z;
}

// Indexing function (note the argument order)
__host__ __device__ int index(int z, int y, int x){
    return z * DATA_DIM*DATA_DIM + y*DATA_DIM + x;
}

// Trilinear interpolation
__host__ __device__ float value_at(float3 pos, unsigned char* data){
    if(!inside(pos)){
        return 0;
    }

    int x = floor(pos.x);
    int y = floor(pos.y);
    int z = floor(pos.z);

    int x_u = ceil(pos.x);
    int y_u = ceil(pos.y);
    int z_u = ceil(pos.z);

    float rx = pos.x - x;
    float ry = pos.y - y;
    float rz = pos.z - z;

    float a0 = rx*data[index(z,y,x)] + (1-rx)*data[index(z,y,x_u)];
    float a1 = rx*data[index(z,y_u,x)] + (1-rx)*data[index(z,y_u,x_u)];
    float a2 = rx*data[index(z_u,y,x)] + (1-rx)*data[index(z_u,y,x_u)];
    float a3 = rx*data[index(z_u,y_u,x)] + (1-rx)*data[index(z_u,y_u,x_u)];

    float b0 = ry*a0 + (1-ry)*a1;
    float b1 = ry*a2 + (1-ry)*a3;

    float c0 = rz*b0 + (1-rz)*b1;


    return c0;
}


// Serial ray casting
unsigned char* raycast_serial(unsigned char* data, unsigned char* region){
    unsigned char* image = (unsigned char*)malloc(sizeof(unsigned char)*IMAGE_DIM*IMAGE_DIM);

    // Camera/eye position, and direction of viewing. These can be changed to look
    // at the volume from different angles.
    float3 camera = {.x=1000,.y=1000,.z=1000};
    float3 forward = {.x=-1, .y=-1, .z=-1};
    float3 z_axis = {.x=0, .y=0, .z = 1};

    // Finding vectors aligned with the axis of the image
    float3 right = cross(forward, z_axis);
    float3 up = cross(right, forward);

    // Creating unity lenght vectors
    forward = normalize(forward);
    right = normalize(right);
    up = normalize(up);

    float fov = 3.14/4;
    float pixel_width = tan(fov/2.0)/(IMAGE_DIM/2);
    float step_size = 0.5;

    // For each pixel
    for(int y = -(IMAGE_DIM/2); y < (IMAGE_DIM/2); y++){
        for(int x = -(IMAGE_DIM/2); x < (IMAGE_DIM/2); x++){

            // Find the ray for this pixel
            float3 screen_center = add(camera, forward);
            float3 ray = add(add(screen_center, scale(right, x*pixel_width)), scale(up, y*pixel_width));
            ray = add(ray, scale(camera, -1));
            ray = normalize(ray);
            float3 pos = camera;

            // Move along the ray, we stop if the color becomes completely white,
            // or we've done 5000 iterations (5000 is a bit arbitrary, it needs 
            // to be big enough to let rays pass through the entire volume)
            int i = 0;
            float color = 0;
            while(color < 255 && i < 5000){
                i++;
                pos = add(pos, scale(ray, step_size));          // Update position
                int r = value_at(pos, region);                  // Check if we're in the region
                color += value_at(pos, data)*(0.01 + r) ;       // Update the color based on data value, and if we're in the region
            }

            // Write final color to image
            image[(y+(IMAGE_DIM/2)) * IMAGE_DIM + (x+(IMAGE_DIM/2))] = color > 255 ? 255 : color;
        }
    }

    return image;
}


// Check if two values are similar, threshold can be changed.
__host__ __device__ int similar(unsigned char* data, int3 a, int3 b){
    unsigned char va = data[a.z * DATA_DIM*DATA_DIM + a.y*DATA_DIM + a.x];
    unsigned char vb = data[b.z * DATA_DIM*DATA_DIM + b.y*DATA_DIM + b.x];

    int i = abs(va-vb) < 1;
    return i;
}


// Serial region growing, same algorithm as in assignment 2
unsigned char* grow_region_serial(unsigned char* data){
    unsigned char* region = (unsigned char*)calloc(sizeof(unsigned char), DATA_DIM*DATA_DIM*DATA_DIM);

    stack_t* stack = new_stack();

    int3 seed = {.x=50, .y=300, .z=300};
    push(stack, seed);
    region[seed.z *DATA_DIM*DATA_DIM + seed.y*DATA_DIM + seed.x] = 1;

    int dx[6] = {-1,1,0,0,0,0};
    int dy[6] = {0,0,-1,1,0,0};
    int dz[6] = {0,0,0,0,-1,1};

    while(stack->size > 0){
        int3 pixel = pop(stack);
        for(int n = 0; n < 6; n++){
            int3 candidate = pixel;
            candidate.x += dx[n];
            candidate.y += dy[n];
            candidate.z += dz[n];

            if(!inside(candidate)){
                continue;
            }

            if(region[candidate.z * DATA_DIM*DATA_DIM + candidate.y*DATA_DIM + candidate.x]){
                continue;
            }

            if(similar(data, pixel, candidate)){
                push(stack, candidate);
                region[candidate.z * DATA_DIM*DATA_DIM + candidate.y*DATA_DIM + candidate.x] = 1;
            }
        }
    }

    return region;
}


__global__ void raycast_kernel(unsigned char* data, unsigned char* image, unsigned char* region){
    // Camera/eye position, and direction of viewing. These can be changed to look
    // at the volume from different angles.
    float3 camera = {.x=1000,.y=1000,.z=1000};
    float3 forward = {.x=-1, .y=-1, .z=-1};
    float3 z_axis = {.x=0, .y=0, .z = 1};

    // Finding vectors aligned with the axis of the image
    float3 right = cross(forward, z_axis);
    float3 up = cross(right, forward);

    // Creating unity lenght vectors
    forward = normalize(forward);
    right = normalize(right);
    up = normalize(up);

    float fov = float(3.14)/4;
    float pixel_width = tan(fov/float(2.0))/(IMAGE_DIM/2);
    float step_size = 0.5;

    int blocks_per_row = IMAGE_DIM/blockDim.x;

    int x 
        = (blockIdx.x % blocks_per_row) * blockDim.x 
        + threadIdx.x 
        - (IMAGE_DIM/2);

    int y 
        = blockIdx.x/blocks_per_row  
        - (IMAGE_DIM/2);

    // Find the ray for this pixel
    float3 screen_center = add(camera, forward);
    float3 ray = add(add(screen_center, scale(right, x*pixel_width)), scale(up, y*pixel_width));
    ray = add(ray, scale(camera, -1));
    ray = normalize(ray);
    float3 pos = camera;

    // Move along the ray
    int i = 0;
    float color = 0;
    while(color < 255 && i < 5000){
        i++;
        pos = add(pos, scale(ray, step_size));          // Update position
        int r = value_at(pos, region);                  // Check if we're in the region
        color += value_at(pos, data)*(float(0.01) + r) ;       // Update the color based on data value, and if we're in the region
    }

    // Write final color to image
    image[(y+(IMAGE_DIM/2)) * IMAGE_DIM + (x+(IMAGE_DIM/2))] = color > 255 ? 255 : color;
}


__global__ void raycast_kernel_texture(unsigned char* image){
    // Camera/eye position, and direction of viewing. These can be changed to look
    // at the volume from different angles.
    float3 camera = {.x=1000,.y=1000,.z=1000};
    float3 forward = {.x=-1, .y=-1, .z=-1};
    float3 z_axis = {.x=0, .y=0, .z = 1};

    // Finding vectors aligned with the axis of the image
    float3 right = cross(forward, z_axis);
    float3 up = cross(right, forward);

    // Creating unity lenght vectors
    forward = normalize(forward);
    right = normalize(right);
    up = normalize(up);

    float fov = float(3.14)/4;
    float pixel_width = tan(fov/float(2.0))/(IMAGE_DIM/2);
    float step_size = 0.5;

    //Calculate x and y.
    int blocks_per_row = IMAGE_DIM/blockDim.x;
    int x 
        = (blockIdx.x % blocks_per_row) * blockDim.x 
        + threadIdx.x 
        - (IMAGE_DIM/2);

    int y 
        = blockIdx.x/blocks_per_row  
        - (IMAGE_DIM/2);

    if(x >= 512 || y >= 512){
        return;
    }
    
    // Find the ray for this pixel
    float3 screen_center = add(camera, forward);
    float3 ray = add(add(screen_center, scale(right, x*pixel_width)), scale(up, y*pixel_width));
    ray = add(ray, scale(camera, -1));
    ray = normalize(ray);
    float3 pos = camera;

    // Move along the ray
    int i = 0;
    float color = 0;
    while(color < 255 && i < 5000){
        i++;
        pos = add(pos, scale(ray, step_size));          // Update position

        //Note that the texture is set to interpolate automatically
        int r = 255 * tex3D(region_texture, pos.x, pos.y, pos.z);    // Look up value from texture
        if(inside(pos)){
            color += 255 * tex3D(data_texture, pos.x, pos.y, pos.z)*(float(0.01) + r) ;       // Update the color based on data value, and if we're in the region
        }
    }

    // Write final color to image
    image[(y+(IMAGE_DIM/2)) * IMAGE_DIM + (x+(IMAGE_DIM/2))] = color > 255 ? 255 : color;

}


unsigned char* raycast_gpu(unsigned char* data, unsigned char* region){

    //Declare and allocate device memory
    unsigned char* device_image;
    unsigned char* device_data;
    unsigned char* device_region;

    cudaMalloc(&device_image, IMAGE_SIZE_BYTES); 
    cudaMalloc(&device_data, DATA_SIZE_BYTES);
    cudaMalloc(&device_region, DATA_SIZE_BYTES);

    //Copy data to the device
    cudaMemcpy(device_data, data, DATA_SIZE_BYTES, cudaMemcpyHostToDevice);
    cudaMemcpy(device_region, region, DATA_SIZE_BYTES, cudaMemcpyHostToDevice);

    int blocks_per_row = 64; //Must divide IMAGE_DIM. Can max be 64
    int grid_size = IMAGE_DIM * blocks_per_row;
    int block_size = IMAGE_DIM / blocks_per_row;

    //Run the kernel
    raycast_kernel<<<grid_size, block_size>>>(device_data, device_image, device_region);  

    //Allocate memory for the result
    unsigned char* host_image = (unsigned char*)malloc(IMAGE_SIZE_BYTES);

    //Copy result from device
    cudaMemcpy(host_image, device_image, IMAGE_SIZE_BYTES, cudaMemcpyDeviceToHost);

    //Free device memory
    cudaFree(device_region);
    cudaFree(device_data);
    cudaFree(device_image);
    return host_image;
}


unsigned char* raycast_gpu_texture(unsigned char* data, unsigned char* region){

    //We let the texture interpolate automatically
    data_texture.filterMode = cudaFilterModeLinear; 
    region_texture.filterMode = cudaFilterModeLinear; 

    cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc(8,0,0,0,cudaChannelFormatKindUnsigned);
    cudaExtent extent = make_cudaExtent(DATA_DIM, DATA_DIM, DATA_DIM);

    //Allocate arrays
    cudaArray* data_array;
    cudaArray* region_array;
    cudaMalloc3DArray(&region_array, &channelDesc, extent, 0);
    cudaMalloc3DArray(&data_array, &channelDesc, extent, 0);

    //Copy data to region array
    cudaMemcpy3DParms copyParams = {0};
    copyParams.srcPtr   = make_cudaPitchedPtr(region, sizeof(char) * IMAGE_DIM, IMAGE_DIM, IMAGE_DIM);
    copyParams.dstArray = region_array;
    copyParams.extent   = extent;
    copyParams.kind     = cudaMemcpyHostToDevice;
    cudaMemcpy3D(&copyParams);

    //Copy data to data array
    copyParams.srcPtr   = make_cudaPitchedPtr(data, sizeof(char) * IMAGE_DIM, IMAGE_DIM, IMAGE_DIM);
    copyParams.dstArray = data_array;
    copyParams.extent   = extent;
    copyParams.kind     = cudaMemcpyHostToDevice;
    cudaMemcpy3D(&copyParams);

    //Bind arrays to the textures
    cudaBindTextureToArray(data_texture, data_array);
    cudaBindTextureToArray(region_texture, region_array);

    //Allocate memory for the result on the device
    unsigned char* device_image;
    cudaMalloc(&device_image, IMAGE_SIZE_BYTES); 

    int blocks_per_row = 1; //Must divide IMAGE_DIM. Can max be 64
    int grid_size = IMAGE_DIM * blocks_per_row;
    int block_size = IMAGE_DIM / blocks_per_row;
    raycast_kernel_texture<<<grid_size, block_size>>>(device_image);  

    //Allocate memory to retrieve the result
    unsigned char* host_image = (unsigned char*)malloc(sizeof(unsigned char)*IMAGE_DIM*IMAGE_DIM);

    //Fetch the result
    cudaMemcpy(host_image, device_image, IMAGE_SIZE_BYTES, cudaMemcpyDeviceToHost);

    //Unbind textures
    cudaUnbindTexture(data_texture);
    cudaUnbindTexture(region_texture);

    //Free memory on the device
    cudaFreeArray(data_array);
    cudaFreeArray(region_array);
    cudaFree(device_image);

    return host_image;
}


__global__ void region_grow_kernel(unsigned char* data, unsigned char* region, int* unfinished){

    int3 voxel;
    voxel.x = blockIdx.x * blockDim.x + threadIdx.x;
    voxel.y = blockIdx.y * blockDim.y + threadIdx.y;
    voxel.z = blockIdx.z * blockDim.z + threadIdx.z;

    int ind = index(voxel.z, voxel.y, voxel.x);

    if(region[ind] == 2){
        //Race conditions should not matter, as we only write 1s, and if one of them gets through it's enough
        *unfinished = 1; 
        region[ind] = 1;

        int dx[6] = {-1,1,0,0,0,0};
        int dy[6] = {0,0,-1,1,0,0};
        int dz[6] = {0,0,0,0,-1,1};



        for(int n = 0; n < 6; n++){
            int3 candidate;
            candidate.x = voxel.x + dx[n];
            candidate.y = voxel.y + dy[n];
            candidate.z = voxel.z + dz[n];

            if(!inside(candidate)){
                continue;
            }

            if(region[index(candidate.z, candidate.y, candidate.x)]){
                continue;
            }

            if(similar(data, voxel, candidate)){
                region[index(candidate.z, candidate.y, candidate.x)] = 2;
            }
        }

    }
}

__device__ bool is_halo(int3 voxel, int dim){

    if( voxel.x == 0 || voxel.y == 0 || voxel.z == 0){
        return true;
    }
    if( voxel.x == dim - 1 || voxel.y == dim - 1 || voxel.z == dim - 1){
        return true;
    }

    return false;
}


__global__ void region_grow_kernel_shared(unsigned char* data, unsigned char* region_global, int* unfinished){
    
    //Shared array within the block. The halo of this 3D cube overlaps with other blocks
    extern __shared__ unsigned char region_local[];
    __shared__ bool block_done;

    //Index of this voxel within shared data region_local
    int3 voxel_local;
    voxel_local.x = threadIdx.x;
    voxel_local.y = threadIdx.y;
    voxel_local.z = threadIdx.z;

    //Index of this voxel in the region_local
    int index_local 
        = voxel_local.z * blockDim.y * blockDim.x 
        + voxel_local.y * blockDim.x
        + voxel_local.x;

    //Global coordinates of this voxel
    int3 voxel_global; 
    voxel_global.x = blockIdx.x * (blockDim.x - 2) + threadIdx.x - 1;
    voxel_global.y = blockIdx.y * (blockDim.y - 2) + threadIdx.y - 1; 
    voxel_global.z = blockIdx.z * (blockDim.z - 2) + threadIdx.z - 1; 

    //Index of this voxel in region_global 
    int index_global = index(voxel_global.z, voxel_global.y, voxel_global.x);

    /*
       Some of our threads will be out of bounds of the global array.
       However, we can not simply return as in the other region grow kernel,
       because we are using __syncthreads(), which might deadlock if some
       threads have returned.

       Incidentally it did not deadlock with returns here instead, but that might be
       because some GPUs, but not all, keep a counter of live threads in a
       block and use it for synchronization instead of the initial count.
       Also, the barrier count is incremented with 32 each time a warp reaches the
       __syncthreads, so if the returning threads does not reduce the number of 
       warps, it would also not deadlock.
       Anyway, returning and then using __syncthreads is a bad, bad idea.
     */
    if(inside(voxel_global)){
        //Copy global data into the shared block. Each thread copies one value
        region_local[index_local] = region_global[index_global];
    }


    do{
        block_done = true;

        //Sync threads here to make sure both data copy and block_done = true is completed
        __syncthreads();

        //Important not to grow 2s on the halo, as they can't reach all neighbours
        //We also don't execute this for pixels outside the global volume
        if(region_local[index_local] == 2 
                && !is_halo(voxel_local, blockDim.x)
                && inside(voxel_global)){

            region_local[index_local] = 1;

            int dx[6] = {-1,1,0,0,0,0};
            int dy[6] = {0,0,-1,1,0,0};
            int dz[6] = {0,0,0,0,-1,1};

            for(int n = 0; n < 6; n++){
                int3 candidate_local;
                candidate_local.x = voxel_local.x + dx[n];
                candidate_local.y = voxel_local.y + dy[n];
                candidate_local.z = voxel_local.z + dz[n];

                int3 candidate_global;
                candidate_global.x = voxel_global.x + dx[n];
                candidate_global.y = voxel_global.y + dy[n];
                candidate_global.z = voxel_global.z + dz[n];

                int candidate_index_local 
                    = candidate_local.z * blockDim.y * blockDim.x 
                    + candidate_local.y * blockDim.x 
                    + candidate_local.x;

                if(region_local[candidate_index_local] != 0){
                    continue;
                }

                if(similar(data, voxel_global, candidate_global)){
                    region_local[candidate_index_local] = 2;
                    block_done = false;
                    *unfinished = 1;
                }
            }
        }
        //We need to sync threads before we check block_done
        __syncthreads();
    }while(!block_done);

    if(!inside(voxel_global)){
        return; //There are no more __syncthreads, so it's safe to return
    }

    if(is_halo(voxel_local, blockDim.x)){
        if(region_local[index_local] == 2){ //Only copy the 2s from the halo
            region_global[index_global] = 2;
        }
    }else{
        //We want to avoid overriding 2s with 0, so only write 1s
        if(region_local[index_local] == 1){
            region_global[index_global] = 1;
        }
    }
}


unsigned char* grow_region_gpu(unsigned char* host_data){
    //Host variables
    unsigned char* host_region = (unsigned char*)calloc(sizeof(unsigned char), DATA_SIZE);
    int            host_unfinished;

    //Device variables
    unsigned char*  device_region;
    unsigned char*  device_data;
    int*            device_unfinished;

    //Allocate device memory
    cudaMalloc(&device_region, DATA_SIZE_BYTES);
    cudaMalloc(&device_data, DATA_SIZE_BYTES);
    cudaMalloc(&device_unfinished, sizeof(int));

    //plant seed
    int3 seed = {.x=50, .y=300, .z=300};
    host_region[index(seed.z, seed.y, seed.x)] = 2;

    //Copy data to device
    cudaMemcpy(device_region, host_region, DATA_SIZE_BYTES, cudaMemcpyHostToDevice);
    cudaMemcpy(device_data, host_data, DATA_SIZE_BYTES, cudaMemcpyHostToDevice);

    //Calculate block and grid sizes
    dim3 block_size;
    block_size.x = 7;
    block_size.y = 7;
    block_size.z = 7;

    dim3 grid_size;
    grid_size.x = DATA_DIM / block_size.x + 1; // Add 1 to round up instead of down.
    grid_size.y = DATA_DIM / block_size.y + 1;
    grid_size.z = DATA_DIM / block_size.z + 1;

    //Run kernel untill completion
    do{
        host_unfinished = 0;
        cudaMemcpy(device_unfinished, &host_unfinished, 1, cudaMemcpyHostToDevice);

        region_grow_kernel<<<grid_size, block_size>>>(device_data, device_region, device_unfinished);

        cudaMemcpy(&host_unfinished, device_unfinished, 1, cudaMemcpyDeviceToHost);

    }while(host_unfinished);

    //Copy result to host
    cudaMemcpy(host_region, device_region, DATA_SIZE_BYTES, cudaMemcpyDeviceToHost);

    //Free device memory
    cudaFree(device_region);
    cudaFree(device_data);
    cudaFree(device_unfinished);

    return host_region;
}


unsigned char* grow_region_gpu_shared(unsigned char* host_data){
    //Host variables
    unsigned char* host_region = (unsigned char*)calloc(sizeof(unsigned char), DATA_SIZE);
    int            host_unfinished;

    //Device variables
    unsigned char*  device_region;
    unsigned char*  device_data;
    int*            device_unfinished;

    //Allocate device memory
    cudaMalloc(&device_region, DATA_SIZE_BYTES);
    cudaMalloc(&device_data, DATA_SIZE_BYTES);
    cudaMalloc(&device_unfinished, sizeof(int));

    //plant seed
    int3 seed = {.x=50, .y=300, .z=300};
    host_region[index(seed.z, seed.y, seed.x)] = 2;

    //Copy data to device
    cudaMemcpy(device_region, host_region, DATA_SIZE_BYTES, cudaMemcpyHostToDevice);
    cudaMemcpy(device_data, host_data, DATA_SIZE_BYTES, cudaMemcpyHostToDevice);

    /* 
       Block size here is padded by 2 to enable overlapping halo.
       So if the block_size is 9x9x9, it is a 7x7x7 block with an overlapping
       halo wrapping it.
     */
    dim3 block_size;
    block_size.x = 10;
    block_size.y = 10;
    block_size.z = 10;

    /*
       Grid size is calculated without the halos, hence -2.
     */
    dim3 grid_size;
    grid_size.x = DATA_DIM / (block_size.x - 2) + 1; 
    grid_size.y = DATA_DIM / (block_size.y - 2) + 1;
    grid_size.z = DATA_DIM / (block_size.z - 2) + 1;

    //Calculate the size of the shared region array within the kernel
    int local_region_size = sizeof(char) * block_size.x * block_size.y * block_size.z;

    //Execute the kernel untill done
    do{
        host_unfinished = 0;
        cudaMemcpy(device_unfinished, &host_unfinished, 1, cudaMemcpyHostToDevice);

        region_grow_kernel_shared<<<grid_size, block_size, local_region_size>>>(device_data, device_region, device_unfinished);

        cudaMemcpy(&host_unfinished, device_unfinished, 1, cudaMemcpyDeviceToHost);
    }while(host_unfinished != 0);

    //Copy result to host
    cudaMemcpy(host_region, device_region, DATA_SIZE_BYTES, cudaMemcpyDeviceToHost);

    //Free device memory
    cudaFree(device_region);
    cudaFree(device_data);
    cudaFree(device_unfinished);

    return host_region;
}

int main(int argc, char** argv){
    struct timeval start, end;

    print_properties();

    unsigned char* data = create_data();

    /*-------REGION GROWING--------*/
    gettimeofday(&start, NULL);
    unsigned char* region = grow_region_gpu_shared(data);
    gettimeofday(&end, NULL);
    printf("\nGrow time:\n");
    print_time(start, end);
    printf("Errors: %s\n", cudaGetErrorString(cudaGetLastError()));


    /*-------RAY CASTING --------*/
    gettimeofday(&start, NULL);
    unsigned char* image = raycast_gpu_texture(data, region);
    gettimeofday(&end, NULL);
    printf("\nRaycast time: \n");
    print_time(start, end);
    printf("Errors: %s\n", cudaGetErrorString(cudaGetLastError()));


    write_bmp(image, IMAGE_DIM, IMAGE_DIM);

    free(data);
    free(region);
    free(image);
}
