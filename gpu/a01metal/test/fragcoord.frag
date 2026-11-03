#version 450
// a01vktex V6: the pixel position as the colour (no varyings at all).
layout(location = 0) out vec4 color;
void main()
{
	color = vec4(gl_FragCoord.xy / 64.0, 0.0, 1.0);
}
