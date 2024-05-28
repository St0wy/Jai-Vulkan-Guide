DescriptorLayoutBuilder :: struct
{
	bindings: [..] VkDescriptorSetLayoutBinding;
	bindings.allocator = temp;
}

AddBindingToBuilder :: (builder: *DescriptorLayoutBuilder, binding: u32, type: VkDescriptorType)
{
	new_binding: VkDescriptorSetLayoutBinding;
	new_binding.binding = binding;
	new_binding.descriptorCount = 1;
	new_binding.descriptorType = type;
	
	array_add(*builder.bindings, new_binding);
}

ClearBuilder :: (builder: *DescriptorLayoutBuilder)
{
	array_reset_keeping_memory(*builder.bindings);
}

BuildDescriptorLayout :: (
	builder: *DescriptorLayoutBuilder, 
	device: VkDevice, 
	shader_stages: VkShaderStageFlags, 
	p_next: *void = null, 
	flags: VkDescriptorSetLayoutCreateFlags = 0
) -> VkDescriptorSetLayout
{
	for *builder.bindings it.stageFlags |= shader_stages;
	
	info: VkDescriptorSetLayoutCreateInfo;
	info.pNext = p_next;
	info.pBindings = builder.bindings.data;
	info.bindingCount = xx builder.bindings.count;
	info.flags = flags;
	
	set: VkDescriptorSetLayout;
	result := vkCreateDescriptorSetLayout(device, *info, null, *set);
	assert(result == .SUCCESS, "Could not create descriptor set layout");
	
	return set;
}

PoolSizeRatio :: struct
{
	type: VkDescriptorType;
	ratio: float32;
}

DescriptorAllocator :: struct
{
	pool: VkDescriptorPool;
}

CreateDescriptorAllocator :: (
	device: VkDevice, 
	max_sets: u32, 
	pool_ratios: [] PoolSizeRatio
) -> DescriptorAllocator
{
	pool_sizes: [] VkDescriptorPoolSize;
	pool_sizes.count = pool_ratios.count;
	pool_sizes.data = temporary_alloc(pool_sizes.count * size_of(VkDescriptorPoolSize));
	
	for pool_ratios pool_sizes[it_index] = 
		VkDescriptorPoolSize.{type = it.type, descriptorCount = cast(u32) it.ratio * max_sets};
		
	pool_info: VkDescriptorPoolCreateInfo;
	pool_info.maxSets = max_sets;
	pool_info.poolSizeCount = xx pool_sizes.count;
	pool_info.pPoolSizes = pool_sizes.data;
	
	descriptor_allocator: DescriptorAllocator;
	result := vkCreateDescriptorPool(device, *pool_info, null, *descriptor_allocator.pool);
	assert(result == .SUCCESS, "Could not create descriptor pool");
	
	return descriptor_allocator;
}

ClearDescriptorAllocator :: (descriptor_allocator: *DescriptorAllocator, device: VkDevice)
{
	result := vkResetDescriptorPool(device, descriptor_allocator.pool, 0);
	assert(result == .SUCCESS, "Could not reset descriptor pool");
}

DestroyPool :: (descriptor_allocator: *DescriptorAllocator, device: VkDevice)
{
	vkDestroyDescriptorPool(device, descriptor_allocator.pool, null);
}

AllocateDescriptorSet :: (
	descriptor_allocator: *DescriptorAllocator, 
	device: VkDevice, 
	layout: VkDescriptorSetLayout
) -> VkDescriptorSet
{
	alloc_info: VkDescriptorSetAllocateInfo;
	alloc_info.descriptorPool = descriptor_allocator.pool;
	alloc_info.descriptorSetCount = 1;
	alloc_info.pSetLayouts = *layout;
	
	descriptor_set: VkDescriptorSet;
	result := vkAllocateDescriptorSets(device, *alloc_info, *descriptor_set);
	assert(result == .SUCCESS, "Could not allocate descriptor sets");
	
	return descriptor_set;
}
