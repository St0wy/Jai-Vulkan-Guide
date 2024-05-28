#version 460 core
layout(location = 0) out vec4 fColor;

layout(set=0, binding=0) uniform sampler2D sTexture;

layout(location = 0) in struct {
    vec4 Color;
    vec2 UV;
} In;

void main()
{
	vec4 color = In.Color * texture(sTexture, In.UV.st);
	vec3 corrected = pow(color.rgb, vec3(2.2));
	fColor = vec4(corrected, color.a);
}
