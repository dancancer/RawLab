/*
 * Copyright (c) 2014, Rafat Hussain
 * Copyright (c) 2016, Holger Nahrstaedt
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
 *
 *  1.  Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 *
 *  2.  Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer
 *  	in the documentation and/or other materials provided with the distribution.
 *
 *  3.  The name of the author may not be used to endorse or promote products derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
 * GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
 *  OF SUCH DAMAGE.
 *
 * Local SWT2 inverse correction: enumerate row and column phases independently.
 * Verified against PyWavelets 1.8.0, including modified coefficients.
 */
static void swt2_roll(double *data, int rows, int cols, int row_shift, int col_shift) {
	int i, k, source_i, source_k;
	double *tmp;
	if (row_shift == 0 && col_shift == 0) {
		return;
	}
	tmp = (double*)malloc(sizeof(double) * rows * cols);
	for (i = 0; i < rows; ++i) {
		for (k = 0; k < cols; ++k) {
			source_i = (i - row_shift + rows) % rows;
			source_k = (k - col_shift + cols) % cols;
			tmp[i * cols + k] = data[source_i * cols + source_k];
		}
	}
	memcpy(data, tmp, sizeof(double) * rows * cols);
	free(tmp);
}

static void rawlab_iswt2_phases(wt2_object wt, double *wavecoeffs, double *oup) {
	int i, k, iter, phase, phase_h, phase_w, it3, J, M, rows, cols, lf, ir,ic,k1,i1;
	double *A, *H, *V, *D,*oup1,*oup2,*oup3,*oup4;
	int aLL, aLH, aHL, aHH, phase_start_h, phase_start_w;
	J = wt->J;
	rows = wt->rows;
	cols = wt->cols;
	lf = wt->wave->lpd_len;
	A = (double*)calloc((rows + lf)*(cols + lf), sizeof(double));
	H = (double*)calloc((rows + lf)*(cols + lf), sizeof(double));
	V = (double*)calloc((rows + lf)*(cols + lf), sizeof(double));
	D = (double*)calloc((rows + lf)*(cols + lf), sizeof(double));
	oup1 = (double*)calloc((rows + lf)*(cols + lf), sizeof(double));
	oup2 = (double*)calloc((rows + lf)*(cols + lf), sizeof(double));
	oup3 = (double*)calloc((rows + lf)*(cols + lf), sizeof(double));
	oup4 = (double*)calloc((rows + lf)*(cols + lf), sizeof(double));

	aLL = wt->coeffaccess[0];

	for (i = 0; i < rows; ++i) {
		for (k = 0; k < cols; ++k) {
			oup[i*cols + k] = wavecoeffs[aLL + i*cols + k];
		}
	}

	for (iter = J; iter > 0; iter--) {
		aLH = wt->coeffaccess[(J - iter) * 3 + 1];
		aHL = wt->coeffaccess[(J - iter) * 3 + 2];
		aHH = wt->coeffaccess[(J - iter) * 3 + 3];
		M = (int)pow(2.0, (double)iter - 1);

		for (phase_h = 0; phase_h < M; ++phase_h) {
			for (phase_w = 0; phase_w < M; ++phase_w) {
				/* SWT2 needs all independent row/column phases, not only diagonal phases. */
				for (phase = 0; phase < 4; ++phase) {
					phase_start_h = phase_h + (phase / 2) * M;
					phase_start_w = phase_w + (phase % 2) * M;
					ir = 0;
					ic = 0;
					it3 = 0;
					for (i = phase_start_h; i < rows; i += 2 * M) {
						ic = 0;
						for (k = phase_start_w; k < cols; k += 2 * M) {
							A[it3] = oup[i*cols + k];
							H[it3] = wavecoeffs[aLH + i*cols + k];
							V[it3] = wavecoeffs[aHL + i*cols + k];
							D[it3] = wavecoeffs[aHH + i*cols + k];
							it3++;
							ic++;
						}
						ir++;
					}
					idwt2_shift(0, ir, ic, wt->wave->lpr, wt->wave->hpr, wt->wave->lpd_len,
						A, H, V, D, phase == 0 ? oup1 : phase == 1 ? oup2 : phase == 2 ? oup3 : oup4);
					if (phase != 0) {
						swt2_roll(phase == 2 ? oup3 : phase == 3 ? oup4 : oup2,
							2 * ir, 2 * ic, phase / 2, phase % 2);
					}
				}
				/* Shift each reconstruction then average all four phase combinations. */
				i1 = 0;
				for (i = phase_h; i < rows; i += M) {
					k1 = 0;
					for (k = phase_w; k < cols; k += M) {
						oup[i*cols+k] = 0.25*(oup1[i1*2*ic + k1] + oup2[i1*2*ic+k1] +
							oup3[i1*2*ic+k1] + oup4[i1*2*ic+k1]);
						k1++;
					}
					i1++;
				}
			}
		}

	}

	free(A);
	free(H);
	free(V);
	free(D);
	free(oup1);
	free(oup2);
	free(oup3);
	free(oup4);
}

/* For orthogonal db2, averaging all decimated phases is exactly the transpose
 * filter bank with a factor of 1/2 per axis, including modified coefficients. */
void iswt2(wt2_object wt, double *wavecoeffs, double *oup) {
    if (strcmp(wt->wave->wname, "db2") != 0) {
        rawlab_iswt2_phases(wt, wavecoeffs, oup);
        return;
    }
    const int rows = wt->rows, cols = wt->cols, taps = wt->wave->lpd_len;
    const size_t count = (size_t)rows * cols;
    double *low = (double*)malloc(count * sizeof(double));
    double *high = (double*)malloc(count * sizeof(double));
    if (!low || !high) {
        free(low); free(high);
        rawlab_iswt2_phases(wt, wavecoeffs, oup);
        return;
    }
    memcpy(oup, wavecoeffs + wt->coeffaccess[0], count * sizeof(double));
    for (int level = wt->J; level > 0; --level) {
        const int step = 1 << (level - 1), center = step * taps / 2;
        const double *h = wavecoeffs + wt->coeffaccess[(wt->J - level) * 3 + 1];
        const double *v = wavecoeffs + wt->coeffaccess[(wt->J - level) * 3 + 2];
        const double *d = wavecoeffs + wt->coeffaccess[(wt->J - level) * 3 + 3];
        for (int y = 0; y < rows; ++y) {
            double *lo = low + y * cols, *hi = high + y * cols;
            memset(lo, 0, cols * sizeof(double));
            memset(hi, 0, cols * sizeof(double));
            for (int tap = 0; tap < taps; ++tap) {
                int source = (y - center + tap * step) % rows;
                if (source < 0) source += rows;
                const int offset = source * cols;
                const double a = wt->wave->lpd[tap] * .5, b = wt->wave->hpd[tap] * .5;
                for (int x = 0; x < cols; ++x) {
                    lo[x] += a * oup[offset + x] + b * h[offset + x];
                    hi[x] += a * v[offset + x] + b * d[offset + x];
                }
            }
        }
        for (int y = 0; y < rows; ++y) {
            double *line = oup + y * cols;
            const double *lo = low + y * cols, *hi = high + y * cols;
            memset(line, 0, cols * sizeof(double));
            for (int tap = 0; tap < taps; ++tap) {
                int shift = (-center + tap * step) % cols;
                if (shift < 0) shift += cols;
                const double a = wt->wave->lpd[tap] * .5, b = wt->wave->hpd[tap] * .5;
                const int split = cols - shift;
                for (int x = 0; x < split; ++x)
                    line[x] += a * lo[x + shift] + b * hi[x + shift];
                for (int x = split; x < cols; ++x)
                    line[x] += a * lo[x - split] + b * hi[x - split];
            }
        }
    }
    free(low); free(high);
}
