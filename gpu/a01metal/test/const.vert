#version 450
// a01vktex V4: a constant varying (smooth): is the vertex output reaching the pixel?
layout(location = 0) out vec2 uv;
void main()
{
	vec2 p = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
	uv = vec2(0.5, 0.25);
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
