// https://github.com/nvpro-samples/optix_prime_baking/blob/332a886f1ac46c0b3eea9e89a59593470c755a0e/random.h
uint tea(uint val0, uint val1) {
  uint v0 = val0;
  uint v1 = val1;
  uint s0 = 0;

  for(uint n = 0; n < 16; n++)
  {
    s0 += 0x9e3779b9;
    v0 += ((v1 << 4) + 0xa341316c) ^ (v1 + s0) ^ ((v1 >> 5) + 0xc8013ea4);
    v1 += ((v0 << 4) + 0xad90777d) ^ (v0 + s0) ^ ((v0 >> 5) + 0x7e95761e);
  }

  return v0;
}

// https://github.com/nvpro-samples/optix_prime_baking/blob/332a886f1ac46c0b3eea9e89a59593470c755a0e/random.h
uint lcg(inout uint prev) {
  uint LCG_A = 1664525u;
  uint LCG_C = 1013904223u;
  prev = (LCG_A * prev + LCG_C);
  return prev & 0x00FFFFFF;
}

// https://github.com/nvpro-samples/optix_prime_baking/blob/332a886f1ac46c0b3eea9e89a59593470c755a0e/random.h
float rnd(inout uint prev) {
  return (float(lcg(prev)) / float(0x01000000));
}

vec3 cosine_weighted_sample(inout uint prev, mat3 matrix) {
    const float PI = 3.14159265359;

	float e1 = rnd(prev);
	float e2 = rnd(prev);

	float x = cos(2.0*PI*e1) * sqrt(e2);
	float y = sin(2.0*PI*e1) * sqrt(e2);
	float z = sqrt(1.0 - e2);
	return vec3(
	  cos(2.0 * PI * e1) * sqrt(e2),
	  sin(2.0 * PI * e1) * sqrt(e2),
	  sqrt(1.0 - e2)
	) * matrix;
}
