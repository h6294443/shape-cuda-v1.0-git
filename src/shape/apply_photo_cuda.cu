/*****************************************************************************************
                                                                            apply_photo.c

For each plane-of-sky pixel, compute the model's scattered optical power per unit
projected (POS) area per unit solid angle per unit incident flux, and then sum these
values over the entire POS.  (The POS pixel area is multiplied in elsewhere.)

The expressions given here differ from the bidirectional reflectance functions defined by,
say, Hapke 1993: bidirectional reflectance includes an extra factor of
cos(scattering angle), since it is defined per unit surface area rather than per unit
projected area.

Modified 2014 February 12 by CM:
    Implement multiple optical scatering laws

Modified 2011 September 2 by CM:
    Add the "harmlambert" and "inholambert" optical scattering laws

Modified 2007 August 4 by CM:
    Add body parameter for use with the "orbit" action: it denotes which
        orbiting body's optical power contributions are being computed
        on this call to the routine
    Don't zero out blank-sky and shadowed POS pixels in the sky rendering
        (the pos->b matrix): do it instead in the calling routine by
        having it call the posclr routine.  This way apply_photo can be
        called twice for the "orbit" action, once for each orbiting body.
    Add comp matrix for POS frames

Modified 2006 October 1 by CM:
    Add "intensityfactor" parameter: account for POS pixel area,
        1 AU Sun-target distance, and solar apparent magnitude here
        rather than after calling the routine

Modified 2006 September 1 by CM and MCN:
    For inhomogeneous laws, add check that facet number pos->f[i][j]
        is nonnegative

Modified 2005 September 7 by CM:
    Implement the "harmlommel" "harmhapke" and "harmkaas" optical
        scattering laws

Modified 2005 August 8 by CM:
    Implement the "inhokaas" optical scattering law
    Add some (cosi > 0) checks
    Move "sum == 0" check to the end

Modified 2005 July 4 by CM:
    Changed structure name for the INHOLOMMEL optical scattering law

Modified 2005 March 1 by CM:
    Add NOLAW case

Modified 2005 January 25 by CM:
    Eliminate unused variables

Modified 2004 April 29 by CM:
    Modify Kaasalainen scattering law to use "wt" as the relative
        weighting factor (0 = pure Lommel-Seeliger, 1 = pure Lambert)
        rather than "c" (which ranged from 0 to infinity)

Modified 2004 March 25 by CM:
    hapke routine now takes phase rather than cos(phase) as argument

Modified 2004 February 29 by CM:
    Added comments
    Added Kaasalainen "Lommel-Seeliger + Lambert" scattering law
    Eliminated "type" argument, since this routine was only being
       used to handle optical scattering.  (Radar scattering is
       instead handled by the "radlaw" routine.)
    Added "phase" argument (solar phase angle) so that we can compute
       the phase just once per calculated lightcurve point (in read_dat)
       rather than computing it every time we call apply_photo
*****************************************************************************************/
extern "C" {
#include "head.h"
}

#define TINY 1.0e-40

__device__ struct pos_t *ap_pos;
__device__ unsigned char *ap_type;
__device__ int ap_ilaw, ap_posn;
__device__ int4 ap_xylim;
__device__ double phasefunc, scale_lommsee, scale_lambert, intensityfactor, phase;
__device__ float sum;

__global__ void ap_get_pos_krnl(struct dat_t *ddat, struct mod_t *dmod,
		int set, int frm, unsigned char *type) {
	/* Single-thread kernel */
	if (threadIdx.x == 0) {
		ap_pos = &ddat->set[set].desc.lghtcrv.rend[frm].pos;
		ap_ilaw = ddat->set[set].desc.lghtcrv.ioptlaw;
		//ap_type = &dmod->photo.opttype[ap_ilaw];
		type[0] = dmod->photo.opttype[ap_ilaw];
		ap_posn = ap_pos->n;
		sum = 0.0;
		intensityfactor = (ap_pos->km_per_pixel/AU) * (ap_pos->km_per_pixel/AU);
		phase = ddat->set[set].desc.lghtcrv.solar_phase[frm];
		ap_xylim.w = ap_pos->xlim[0];
		ap_xylim.x = ap_pos->xlim[1];
		ap_xylim.y = ap_pos->ylim[0];
		ap_xylim.z = ap_pos->ylim[1];
	}
}
__global__ void ap_lambertlaw_krnl(struct mod_t *dmod, int nThreads,
		int body, int2 span) {
	/* Multi-threaded kernel */
	int offset = blockIdx.x * blockDim.x + threadIdx.x;
	int i = offset % span.x + ap_xylim.w;
	int j = offset / span.x + ap_xylim.y;
	double scale;
	float b;

	if (offset < nThreads) {
		scale = dmod->photo.optical[ap_ilaw].R.R.val/PIE;

		if (ap_pos->cose[i][j] > 0.0 && ap_pos->cosi[i][j] > 0.0
				&& ap_pos->body[i][j] == body) {
			ap_pos->b[i][j] = intensityfactor * scale * ap_pos->cosi[i][j];
			b = __double2float_rd(ap_pos->b[i][j]);
			atomicAdd(&sum, b);
		}
	}
}
__global__ void ap_harmlambert_krnl(struct mod_t *dmod, int nThreads, int body, int2 span) {
	/* Multi-threaded kernel */
	int offset = blockIdx.x * blockDim.x + threadIdx.x;
	int i = offset % span.x + ap_xylim.w;
	int j = offset / span.x + ap_xylim.y;
	int c, f;
	double scale;
	float b;

	if (offset < nThreads) {

		if (ap_pos->cose[i][j] > 0.0 && ap_pos->cosi[i][j] > 0.0
		 && ap_pos->body[i][j] == body && ap_pos->f[i][j] >= 0) {
			c = ap_pos->comp[i][j];
			f = ap_pos->f[i][j];
			scale = dmod->photo.optical[ap_ilaw].harmR.local[c][f].R.val/PIE;
			ap_pos->b[i][j] = intensityfactor * scale * ap_pos->cosi[i][j];
			b = __double2float_rd(ap_pos->b[i][j]);
			atomicAdd(&sum, b);
		}
	}
}
__global__ void ap_inholambert_krnl(struct mod_t *dmod, int nThreads, int body, int2 span) {
	/* Multi-threaded kernel */
	int offset = blockIdx.x * blockDim.x + threadIdx.x;
	int i = offset % span.x + ap_xylim.w;
	int j = offset / span.x + ap_xylim.y;
	int c, f;
	double scale;
	float b;

	if (offset < nThreads) {

		if (ap_pos->cose[i][j] > 0.0 && ap_pos->cosi[i][j] > 0.0
		 && ap_pos->body[i][j] == body && ap_pos->f[i][j] >= 0) {
			c = ap_pos->comp[i][j];
			f = ap_pos->f[i][j];
			scale = dmod->photo.optical[ap_ilaw].inhoR.local[c][f].R.val/PIE;
			ap_pos->b[i][j] = intensityfactor * scale * ap_pos->cosi[i][j];
			b = __double2float_rd(ap_pos->b[i][j]);
			atomicAdd(&sum, b);
		}
	}
}
__global__ void ap_lommel_krnl(struct mod_t *dmod, int nThreads, int body, int2 span) {
	/* Multi-threaded kernel */
	int offset = blockIdx.x * blockDim.x + threadIdx.x;
	int i = offset % span.x + ap_xylim.w;
	int j = offset / span.x + ap_xylim.y;
	double scale;
	float b;

	if (offset < nThreads) {
		scale = dmod->photo.optical[ap_ilaw].R.R.val/(4*PIE);
		if (ap_pos->cose[i][j] > 0.0 && ap_pos->cosi[i][j] > 0.0
				&& ap_pos->body[i][j] == body) {
			ap_pos->b[i][j] = intensityfactor * scale * ap_pos->cosi[i][j]
			  / (ap_pos->cosi[i][j] + ap_pos->cose[i][j]);
			b = __double2float_rd(ap_pos->b[i][j]);
			atomicAdd(&sum, b);
		}
	}
}
__global__ void ap_harmlommel_krnl(struct mod_t *dmod, int nThreads, int body, int2 span) {
	/* Multi-threaded kernel */
	int offset = blockIdx.x * blockDim.x + threadIdx.x;
	int i = offset % span.x + ap_xylim.w;
	int j = offset / span.x + ap_xylim.y;
	int c, f;
	double scale;
	float b;

	if (offset < nThreads) {
		if (ap_pos->cose[i][j] > 0.0 && ap_pos->cosi[i][j] > 0.0
		 && ap_pos->body[i][j] == body && ap_pos->f[i][j] >= 0) {
			c = ap_pos->comp[i][j];
			f = ap_pos->f[i][j];
			scale = dmod->photo.optical[ap_ilaw].harmR.local[c][f].R.val/(4*PIE);
			ap_pos->b[i][j] = intensityfactor * scale * ap_pos->cosi[i][j]
			   / (ap_pos->cosi[i][j] + ap_pos->cose[i][j]);
			b = __double2float_rd(ap_pos->b[i][j]);
			atomicAdd(&sum, b);
		}
	}
}
__global__ void ap_inholommel_krnl(struct mod_t *dmod, int nThreads, int body, int2 span) {
	/* Multi-threaded kernel */
	int offset = blockIdx.x * blockDim.x + threadIdx.x;
	int i = offset % span.x + ap_xylim.w;
	int j = offset / span.x + ap_xylim.y;
	int c, f;
	double scale;
	float b;

	if (offset < nThreads) {
		if (ap_pos->cose[i][j] > 0.0 && ap_pos->cosi[i][j] > 0.0
		 && ap_pos->body[i][j] == body && ap_pos->f[i][j] >= 0) {
			c = ap_pos->comp[i][j];
			f = ap_pos->f[i][j];
			scale = dmod->photo.optical[ap_ilaw].inhoR.local[c][f].R.val/(4*PIE);
			ap_pos->b[i][j] = intensityfactor * scale * ap_pos->cosi[i][j]
			   / (ap_pos->cosi[i][j] + ap_pos->cose[i][j]);
			b = __double2float_rd(ap_pos->b[i][j]);
			atomicAdd(&sum, b);
		}
	}
}
__global__ void ap_geometrical_krnl(struct mod_t *dmod, int nThreads, int body, int2 span) {
	/* Multi-threaded kernel */
	int offset = blockIdx.x * blockDim.x + threadIdx.x;
	int i = offset % span.x + ap_xylim.w;
	int j = offset / span.x + ap_xylim.y;
	float b;

	if (offset < nThreads) {
		if (ap_pos->cose[i][j] > 0.0 && ap_pos->cosi[i][j] > 0.0
		 && ap_pos->body[i][j] == body) {
			ap_pos->b[i][j] = intensityfactor * dmod->photo.optical[ap_ilaw].R.R.val;
			b = __double2float_rd(ap_pos->b[i][j]);
			atomicAdd(&sum, b);
		}
	}
}
__global__ void ap_hapke_krnl(struct mod_t *dmod, int nThreads, int body, int2 span) {
	/* Multi-threaded kernel */
	int offset = blockIdx.x * blockDim.x + threadIdx.x;
	int i = offset % span.x + ap_xylim.w;
	int j = offset / span.x + ap_xylim.y;
	float b;

	if (offset < nThreads) {
		if (ap_pos->cose[i][j] > 0.0 && ap_pos->cosi[i][j] > 0.0
		 && ap_pos->body[i][j] == body) {
			ap_pos->b[i][j] = intensityfactor
					* dev_hapke(ap_pos->cosi[i][j], ap_pos->cose[i][j],
							phase,
							dmod->photo.optical[ap_ilaw].hapke.w.val,
							dmod->photo.optical[ap_ilaw].hapke.h.val,
							dmod->photo.optical[ap_ilaw].hapke.B0.val,
							dmod->photo.optical[ap_ilaw].hapke.g.val,
							dmod->photo.optical[ap_ilaw].hapke.theta.val);

			b = __double2float_rd(ap_pos->b[i][j]);
			atomicAdd(&sum, b);
		}
	}
}
__global__ void ap_harmhapke_krnl(struct mod_t *dmod, int nThreads, int body, int2 span) {
	/* Multi-threaded kernel */
	int offset = blockIdx.x * blockDim.x + threadIdx.x;
	int i = offset % span.x + ap_xylim.w;
	int j = offset / span.x + ap_xylim.y;
	int c, f;
	float b;

	if (offset < nThreads) {
		if (ap_pos->cose[i][j] > 0.0 && ap_pos->cosi[i][j] > 0.0
	     && ap_pos->body[i][j] == body && ap_pos->f[i][j] >= 0) {
			c = ap_pos->comp[i][j];
			f = ap_pos->f[i][j];
			ap_pos->b[i][j] = intensityfactor
					* dev_hapke(ap_pos->cosi[i][j], ap_pos->cose[i][j],
							phase,
							dmod->photo.optical[ap_ilaw].harmhapke.local[c][f].w.val,
							dmod->photo.optical[ap_ilaw].harmhapke.local[c][f].h.val,
							dmod->photo.optical[ap_ilaw].harmhapke.local[c][f].B0.val,
							dmod->photo.optical[ap_ilaw].harmhapke.local[c][f].g.val,
							dmod->photo.optical[ap_ilaw].harmhapke.local[c][f].theta.val);

			b = __double2float_rd(ap_pos->b[i][j]);
			atomicAdd(&sum, b);
		}
	}
}
__global__ void ap_inhohapke_krnl(struct mod_t *dmod, int nThreads, int body, int2 span) {
	/* Multi-threaded kernel */
	int offset = blockIdx.x * blockDim.x + threadIdx.x;
	int i = offset % span.x + ap_xylim.w;
	int j = offset / span.x + ap_xylim.y;
	int c, f;
	float b;

	if (offset < nThreads) {
		if (ap_pos->cose[i][j] > 0.0 && ap_pos->cosi[i][j] > 0.0
		 && ap_pos->body[i][j] == body && ap_pos->f[i][j] >= 0) {
			c = ap_pos->comp[i][j];
			f = ap_pos->f[i][j];
			ap_pos->b[i][j] = intensityfactor
					* dev_hapke(ap_pos->cosi[i][j], ap_pos->cose[i][j],
							phase,
							dmod->photo.optical[ap_ilaw].inhohapke.local[c][f].w.val,
							dmod->photo.optical[ap_ilaw].inhohapke.local[c][f].h.val,
							dmod->photo.optical[ap_ilaw].inhohapke.local[c][f].B0.val,
							dmod->photo.optical[ap_ilaw].inhohapke.local[c][f].g.val,
							dmod->photo.optical[ap_ilaw].inhohapke.local[c][f].theta.val);

			b = __double2float_rd(ap_pos->b[i][j]);
			atomicAdd(&sum, b);
		}
	}
}
__global__ void ap_kaas_init_krnl(struct mod_t *dmod) {
	/* Single-threaded kernel */
	if (threadIdx.x == 0) {
		phasefunc = dmod->photo.optical[ap_ilaw].kaas.A0.val
				* exp( -phase / dmod->photo.optical[ap_ilaw].kaas.D.val)
		+ dmod->photo.optical[ap_ilaw].kaas.k.val * phase + 1;

		scale_lommsee = (1 - dmod->photo.optical[ap_ilaw].kaas.wt.val)
		 	   * phasefunc * dmod->photo.optical[ap_ilaw].kaas.R.val/(4*PIE);
		scale_lambert = dmod->photo.optical[ap_ilaw].kaas.wt.val
			   * phasefunc * dmod->photo.optical[ap_ilaw].kaas.R.val/PIE;
	}
}
__global__ void ap_kaas_krnl(struct mod_t *dmod, int nThreads, int body, int2 span) {
	/* Multi-threaded kernel */
	int offset = blockIdx.x * blockDim.x + threadIdx.x;
	int i = offset % span.x + ap_xylim.w;
	int j = offset / span.x + ap_xylim.y;
	int n = ap_pos->n;
	int pos_spn = 2*n+1;
	int pxa = (j+n)*pos_spn + (i+n);

	if (offset < nThreads) {
		if (ap_pos->cose_s[pxa] > 0.0 && ap_pos->cosi_s[pxa] > 0.0
		 && ap_pos->body[i][j] == body) {
			ap_pos->b_s[pxa] = intensityfactor * ap_pos->cosi_s[pxa]
			    *(scale_lommsee / (ap_pos->cosi_s[pxa] + ap_pos->cose_s[pxa])
			    + scale_lambert);
			atomicAdd(&sum, ap_pos->b_s[pxa]);
		}
	}
}
__global__ void ap_harmkaas_krnl(struct mod_t *dmod, int nThreads, int body, int2 span) {
	/* Multi-threaded kernel */
	int offset = blockIdx.x * blockDim.x + threadIdx.x;
	int i = offset % span.x + ap_xylim.w;
		int j = offset / span.x + ap_xylim.y;
	int c, f;
	float b;

	if (offset < nThreads) {
		if (ap_pos->cose[i][j] > 0.0 && ap_pos->cosi[i][j] > 0.0
		 && ap_pos->body[i][j] == body && ap_pos->f[i][j] >= 0) {
			c = ap_pos->comp[i][j];
			f = ap_pos->f[i][j];
			phasefunc = dmod->photo.optical[ap_ilaw].harmkaas.local[c][f].A0.val
			* exp( -phase / dmod->photo.optical[ap_ilaw].harmkaas.local[c][f].D.val)
			+ dmod->photo.optical[ap_ilaw].harmkaas.local[c][f].k.val * phase + 1;

			scale_lommsee = (1 - dmod->photo.optical[ap_ilaw].harmkaas.local[c][f].wt.val)
		    * phasefunc * dmod->photo.optical[ap_ilaw].harmkaas.local[c][f].R.val / (4*PIE);
			scale_lambert = dmod->photo.optical[ap_ilaw].harmkaas.local[c][f].wt.val
			* phasefunc * dmod->photo.optical[ap_ilaw].harmkaas.local[c][f].R.val / PIE;
			ap_pos->b[i][j] = intensityfactor * ap_pos->cosi[i][j] * (scale_lommsee /
					(ap_pos->cosi[i][j] + ap_pos->cose[i][j]) + scale_lambert);

			b = __double2float_rd(ap_pos->b[i][j]);
			atomicAdd(&sum, b);
		}
	}
}
__global__ void ap_inhokaas_krnl(struct mod_t *dmod, int nThreads, int body, int2 span) {
	/* Multi-threaded kernel */
	int offset = blockIdx.x * blockDim.x + threadIdx.x;
	int i = offset % span.x + ap_xylim.w;
		int j = offset / span.x + ap_xylim.y;
	int c, f;
	float b;

	if (offset < nThreads) {
		if (ap_pos->cose[i][j] > 0.0 && ap_pos->cosi[i][j] > 0.0
		 && ap_pos->body[i][j] == body && ap_pos->f[i][j] >= 0) {
			c = ap_pos->comp[i][j];
			f = ap_pos->f[i][j];
			phasefunc = dmod->photo.optical[ap_ilaw].inhokaas.local[c][f].A0.val
			* exp( -phase / dmod->photo.optical[ap_ilaw].inhokaas.local[c][f].D.val)
			+ dmod->photo.optical[ap_ilaw].inhokaas.local[c][f].k.val * phase + 1;
			scale_lommsee = (1 - dmod->photo.optical[ap_ilaw].inhokaas.local[c][f].wt.val)
		    * phasefunc * dmod->photo.optical[ap_ilaw].inhokaas.local[c][f].R.val / (4*PIE);
			scale_lambert = dmod->photo.optical[ap_ilaw].inhokaas.local[c][f].wt.val
			* phasefunc * dmod->photo.optical[ap_ilaw].inhokaas.local[c][f].R.val / PIE;
			ap_pos->b[i][j] = intensityfactor * ap_pos->cosi[i][j] * (scale_lommsee /
					(ap_pos->cosi[i][j] + ap_pos->cose[i][j]) + scale_lambert);

			b = __double2float_rd(ap_pos->b[i][j]);
			atomicAdd(&sum, b);
		}
	}
}
__global__ void ap_get_sum_krnl() {
	/* Single-threaded kernel */
	/* Nothing really needs to be done, but we need a kernel that we can
	 * follow with copying the variable out  */
	if (threadIdx.x == 0)
		if (sum == 0)
			sum = TINY; //printf("\nsum =0!\n");
}

__host__ double apply_photo_cuda(struct mod_t *dmod, struct dat_t *ddat, int body,
		int set, int frm)
{
	unsigned char *type;
	int n, nThreads;
	float hsum;
	dim3 BLK, THD;
	int4 xylim;
	int2 span;

	cudaCalloc((void**)&type, sizeof(unsigned char), 2);
	/* Launch single-thread kernel to assign pos address and get type */
	ap_get_pos_krnl<<<1,1>>>(ddat, dmod, set, frm, type);
	checkErrorAfterKernelLaunch("ap_get_pos_krnl");
	deviceSyncAfterKernelLaunch("ap_get_pos_krnl");

//	gpuErrchk(cudaMemcpyFromSymbol(&ilaw, ap_ilaw, sizeof(ilaw), 0,
//			cudaMemcpyDeviceToHost));
	gpuErrchk(cudaMemcpyFromSymbol(&n, ap_posn,	sizeof(n), 0,
			cudaMemcpyDeviceToHost));
	gpuErrchk(cudaMemcpyFromSymbol(&xylim, ap_xylim, sizeof(int4), 0,
			cudaMemcpyDeviceToHost));

	/* Calculate launch parameters for the pixel kernels */
	span.x = xylim.x - xylim.w + 1;
	span.y = xylim.z - xylim.y + 1;
	nThreads = span.x * span.y;
 	BLK.x = floor((maxThreadsPerBlock-1+nThreads)/maxThreadsPerBlock);
	THD.x = maxThreadsPerBlock; // Thread block dimensions

	switch (type[0]) {
	case LAMBERTLAW:
		/* Launch Lambert Law kernel */
		ap_lambertlaw_krnl<<<BLK,THD>>>(dmod, nThreads, body, span);
		checkErrorAfterKernelLaunch("ap_lambertlaw_krnl, line ");
		break;
	case HARMLAMBERT:
		/* Launch the HarmLambert kernel */
		ap_harmlambert_krnl<<<BLK,THD>>>(dmod, nThreads, body, span);
		checkErrorAfterKernelLaunch("ap_harmlambert_krnl, line ");
		break;
	case INHOLAMBERT:
		/* Launch the Inhomogeneous Lambert kernel */
		ap_inholambert_krnl<<<BLK,THD>>>(dmod, nThreads, body, span);
		checkErrorAfterKernelLaunch("ap_inholambert_krnl, line ");
		break;
	case LOMMEL:
		/* Launch the Lommel kernel */
		ap_lommel_krnl<<<BLK,THD>>>(dmod, nThreads, body, span);
		checkErrorAfterKernelLaunch("ap_lommel_krnl, line ");
		break;
	case HARMLOMMEL:
		/* Launch the HarmLommel kernel */
		ap_harmlommel_krnl<<<BLK,THD>>>(dmod, nThreads, body, span);
		checkErrorAfterKernelLaunch("ap_harmlommel_krnl, line ");
		break;
	case INHOLOMMEL:
		/* Launch the Inhomogeneous Lommel kernel */
		ap_harmlommel_krnl<<<BLK,THD>>>(dmod, nThreads, body, span);
		checkErrorAfterKernelLaunch("ap_inholommel_krnl, line ");
      break;
  case GEOMETRICAL:
	  /* Launch the Geometrical law kernel */
	  ap_geometrical_krnl<<<BLK,THD>>>(dmod, nThreads, body, span);
	  checkErrorAfterKernelLaunch("ap_geometrical_krnl, line ");
	  break;
  case HAPKE:
	  /* Launch the Hapke kernel */
	  ap_hapke_krnl<<<BLK,THD>>>(dmod, nThreads, body, span);
	  checkErrorAfterKernelLaunch("ap_hapke_krnl, line ");
      break;
  case HARMHAPKE:
	  /* Launch the HarmHapke kernel */
	  ap_harmhapke_krnl<<<BLK,THD>>>(dmod, nThreads, body, span);
	  checkErrorAfterKernelLaunch("ap_harmhapke_krnl, line ");
      break;
  case INHOHAPKE:
	  /* Launch the Inhomogeneous Hapke kernel */
	  ap_inhohapke_krnl<<<BLK,THD>>>(dmod, nThreads, body, span);
	  checkErrorAfterKernelLaunch("ap_inhohapke_krnl, line ");
	  break;
  case KAASALAINEN:
      /* Launch single-thread kernel to init Kaas */
	  ap_kaas_init_krnl<<<1,1>>>(dmod);
	  checkErrorAfterKernelLaunch("ap_kaas_init_krnl, line ");

	  /* Launch the main Kaasalainen kernel */
	  ap_kaas_krnl<<<BLK,THD>>>(dmod, nThreads, body, span);
	  checkErrorAfterKernelLaunch("ap_kaas_krnl, line ");
      break;
  case HARMKAAS:
	  /* Launch the HarmKaas kernel */
	  ap_harmkaas_krnl<<<BLK,THD>>>(dmod, nThreads, body, span);
	  checkErrorAfterKernelLaunch("ap_harmkaas_krnl, line ");
	  break;
  case INHOKAAS:
	  /* Launch the HarmKaas kernel */
	  ap_inhokaas_krnl<<<BLK,THD>>>(dmod, nThreads, body, span);
	  checkErrorAfterKernelLaunch("ap_inhokaas_krnl, line ");
	  break;
  case NOLAW:
	  bailout("apply_photo.c: can't set optical scattering law = \"none\" when optical data are used\n");
	  break;
  default:
	  bailout("apply_photo.c: can't handle that optical scattering law yet\n");
	}

	/* Launch single kernel to retrieve sum */
	ap_get_sum_krnl<<<1,1>>>();
	checkErrorAfterKernelLaunch("ap_get_sum_krnl, line ");
	gpuErrchk(cudaMemcpyFromSymbol(&hsum, sum, sizeof(sum), 0,
			cudaMemcpyDeviceToHost));
	if (hsum == 0.0)
		hsum = TINY;
	//cudaFree(type);
	return (double)hsum;
}

#undef TINY
