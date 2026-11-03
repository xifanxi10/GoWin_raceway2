#include "Window_DSP.h"
#include "math.h"

#define PI               3.14159265358979f

void dsp_hannWin(float *window, int N)   //汉宁窗函数系数计算
{
	for (uint16_t i = 0; i < N; i++)
	{
		window[i] = 0.5 * (1 - cos(2 * PI * (float)i / (N - 1)));
	}
}

void dsp_flattop(float *window, int len)   //平顶窗窗函数初始化函数
{
	const float a0=0.21557895; 
	const float a1=0.41663158; 
	const float a2=0.277263158; 
	const float a3=0.083578947; 
	const float a4=0.006947368;    
	float len_mult = 1/(float)(len-1);
	for (int i = 0; i < len; i++) {
		  window[i] = a0 
					- a1 * cosf(i * 2 * PI * len_mult) 
					+ a2 * cosf(i * 4 * PI * len_mult)
					- a3 * cosf(i * 6 * PI * len_mult)
					+ a4 * cosf(i * 8 * PI * len_mult);
	}
}
