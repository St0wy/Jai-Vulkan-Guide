#!/bin/bash
## -V: create SPIR-V binary
## -x: save binary output as text-based 32-bit hexadecimal numbers
## -o: output file
glslc glsl_shader.frag -o glsl_shader.frag.spv
glslc glsl_shader.vert -o glsl_shader.vert.spv
