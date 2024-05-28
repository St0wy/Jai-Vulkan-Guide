# Jai Vulkan Guide

This repo contains the code that you could have after following Vulkan Guide until the end of chapter 2.

## Getting started

Clone with :

```
git clone https://github.com/St0wy/Jai-Vulkan-Guide.git --recursive
```

You can compile it with :
```
// Debug
jai build.jai

// Optimized, some optimizations with debug info
jai build.jai - optimized

// Release, full optimizations without debug info
jai build.jai - release
```

## Modules

This project uses a modified version of the Vulkan module that comes with the Jai compiler to have Vulkan 1.3 features : https://gitlab.com/Stowy/jai-vulkan

It also has a modified ImGui module that uses version 1.90.7 of the docking branch : https://gitlab.com/Stowy/jai-imgui

As for SDL, it just has small modifications and VMA uses bindings found on the Jai discord.

The ImGui SDL2 and Vulkan backend are translated by hands in this project, feel free to copy the files if you need them in another project.
