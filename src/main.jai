// Import of global modules
#import "Basic"()(MEMORY_DEBUGGER = BUILD_TYPE != .RELEASE, ENABLE_ASSERT = BUILD_TYPE != .RELEASE);
#import "String";
#import "Math";
#import "File";
#import "Print_Color";

// Import of local modules
#import "SDL"(VULKAN = true);
#import "jai-vulkan";
#import "VMA";
ImGui :: #import "jai-imgui";
for_expansion :: ImGui.for_expansion;

#load "vk_engine.jai";
#load "vk_init.jai";
#load "vk_utils.jai";
#load "vk_descriptors.jai";
#load "utils.jai";
#load "imgui_backends/imgui_impl_sdl2.jai";
#load "imgui_backends/imgui_impl_vulkan.jai";

BuildType :: enum u8
{
	DEBUG;
	OPTIMIZED;
	RELEASE;
}

Logger :: (message: string, data: *void, info: Log_Info)
{
	#if BUILD_TYPE == .RELEASE then return;
	if info.common_flags == .VERBOSE_ONLY && context.log_level != .VERBOSE then return;
	if info.common_flags == .VERY_VERBOSE_ONLY && context.log_level != .VERY_VERBOSE then return;

	color: Console_Color;
	if info.common_flags == .ERROR then color = .RED;
	if info.common_flags == .WARNING then color = .YELLOW;
	
	with_console_color(color, write_string(message));
}

main :: ()
{
	context.logger = Logger;
	
	vulkan_engine := InitVulkanEngine(640, 480);
	if vulkan_engine == null 
	{
		log_error("Error at vulkan engine creation.\n");
		return;
	}
	
	#if BUILD_TYPE != .RELEASE
	{
		defer report_memory_leaks();
		defer print("\n\n **** First Leak Report: ****\n\n");
		defer context.logger = runtime_support_default_logger;
	}
	
	defer DeleteVulkanEngine(vulkan_engine);

	RunVulkanEngine(vulkan_engine);
}
