CommandPoolCreateInfo :: (queue_family_index: u32, flags: VkCommandPoolCreateFlags) -> VkCommandPoolCreateInfo
{
	info: VkCommandPoolCreateInfo;
	info.queueFamilyIndex = queue_family_index;
	info.flags = flags;
	return info;
}


CommandBufferAllocateInfo :: (pool: VkCommandPool, count: u32) -> VkCommandBufferAllocateInfo
{
    info: VkCommandBufferAllocateInfo;
    info.commandPool = pool;
    info.commandBufferCount = count;
    info.level = .PRIMARY;
    return info;
}

FenceCreateInfo :: (flags: VkFenceCreateFlags) -> VkFenceCreateInfo
{
	info: VkFenceCreateInfo;
	info.flags = flags;
	return info;
}


SemaphoreCreateInfo :: (flags: VkSemaphoreCreateFlags = 0) -> VkSemaphoreCreateInfo 
{
    info: VkSemaphoreCreateInfo;
    info.flags = flags;
    return info;
}

CommandBufferBeginInfo :: (flags: VkCommandBufferUsageFlags) -> VkCommandBufferBeginInfo 
{
	info: VkCommandBufferBeginInfo;
	info.flags = flags;
	return info;
}

ImageSubresourceRange :: (aspect_mask: VkImageAspectFlags) -> VkImageSubresourceRange
{
	sub_image: VkImageSubresourceRange;
    sub_image.aspectMask = aspect_mask;
    sub_image.levelCount = VK_REMAINING_MIP_LEVELS;
    sub_image.layerCount = VK_REMAINING_ARRAY_LAYERS;
    return sub_image;
}

SemaphoreSubmitInfo :: (
	stage_mask: VkPipelineStageFlags2, 
	semaphore: VkSemaphore
) -> VkSemaphoreSubmitInfo
{
	submit_info: VkSemaphoreSubmitInfo;
	submit_info.semaphore = semaphore;
	submit_info.stageMask = stage_mask;
	submit_info.value = 1;
	return submit_info;
}

CommandBufferSubmitInfo :: (cmd: VkCommandBuffer) -> VkCommandBufferSubmitInfo
{
	info: VkCommandBufferSubmitInfo;
	info.commandBuffer = cmd;
	return info;
}

SubmitInfo :: (
	cmd: *VkCommandBufferSubmitInfo, 
	signal_semaphore_info: *VkSemaphoreSubmitInfo, 
	wait_semaphore_info: *VkSemaphoreSubmitInfo
) -> VkSubmitInfo2
{
	info: VkSubmitInfo2;
	info.waitSemaphoreInfoCount = ifx wait_semaphore_info then cast(u32) 1 else cast(u32) 0;
    info.pWaitSemaphoreInfos = wait_semaphore_info;

    info.signalSemaphoreInfoCount = ifx signal_semaphore_info then cast(u32) 1 else cast(u32) 0;
    info.pSignalSemaphoreInfos = signal_semaphore_info;

    info.commandBufferInfoCount = 1;
    info.pCommandBufferInfos = cmd;
    return info;
}

ImageCreateInfo :: (
	format: VkFormat, 
	usage_flags: VkImageUsageFlags, 
	extent: VkExtent3D
) -> VkImageCreateInfo
{
	info: VkImageCreateInfo;
	info.imageType = ._2D;
	info.format = format;
	info.extent = extent;
	info.mipLevels = 1;
	info.arrayLayers = 1;
	info.samples = ._1_BIT;
	info.tiling = .OPTIMAL;
	info.usage = usage_flags;
	return info;
}

ImageViewCreateInfo :: (
	format: VkFormat,
	image: VkImage, 
	aspect_flags: VkImageAspectFlags
) -> VkImageViewCreateInfo
{
	info: VkImageViewCreateInfo;
	info.viewType = ._2D;
	info.image = image;
	info.format = format;
	info.subresourceRange.baseMipLevel = 0;
    info.subresourceRange.levelCount = 1;
    info.subresourceRange.baseArrayLayer = 0;
    info.subresourceRange.layerCount = 1;
    info.subresourceRange.aspectMask = aspect_flags;
    return info;
}
