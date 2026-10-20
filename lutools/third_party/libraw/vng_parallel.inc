/*
 * VNG pixel arithmetic derived from LibRaw 0.22.2 misc_demosaic.cpp.
 * Copyright 2019-2025 LibRaw LLC (info@libraw.org).
 * Available under LGPL-2.1 or CDDL-1.0, as with the original LibRaw source.
 */
#ifdef LIBRAW_USE_OPENMP
  if (filters > 1000 && omp_get_max_threads() > 1)
  {
    using VngPixel = ushort[4];
    const int batchRows = 256;
    const size_t rowBytes = size_t(width) * sizeof(VngPixel);
    const auto release = [this](void *pointer) { free(pointer); };
    std::unique_ptr<ushort, decltype(release)> snapshot(
        static_cast<ushort *>(malloc((batchRows + 4) * rowBytes)), release);
    if (snapshot)
    {
      std::unique_ptr<int, decltype(release)> codeOwner(code[0][0], release);
      auto source = reinterpret_cast<VngPixel *>(snapshot.get());
      memcpy(source, image, 4 * rowBytes);
      for (int first = 2; first < height - 2; first += batchRows)
      {
        const int count = MIN(batchRows, height - 2 - first);
        // 回调只在调用线程运行；取消异常不跨越 OpenMP 区域。
        RUN_CALLBACK(LIBRAW_PROGRESS_INTERPOLATE, (first - 2) / 256 + 1,
                     ((height - 3) / 256) + 1);
        memcpy(source + size_t(4) * width, image + size_t(first + 2) * width,
               size_t(count) * rowBytes);
#pragma omp parallel for schedule(static)
        for (int r = first; r < first + count; ++r)
        {
          for (int col = 2; col < width - 2; ++col)
          {
            const ushort *pix = source[size_t(r - first + 2) * width + col];
            ushort *out = image[size_t(r) * width + col];
            const int *ip = code[r % prow][col % pcol];
            int gval[8] = {}, sum[4] = {}, g;
            while ((g = ip[0]) != INT_MAX)
            {
              const int diff = ABS(pix[g] - pix[ip[1]]) << ip[2];
              gval[ip[3]] += diff;
              ip += 5;
              if ((g = ip[-1]) == -1)
                continue;
              gval[g] += diff;
              while ((g = *ip++) != -1)
                gval[g] += diff;
            }
            ++ip;
            int gmin = gval[0], gmax = gval[0];
            for (g = 1; g < 8; ++g)
            {
              if (gmin > gval[g]) gmin = gval[g];
              if (gmax < gval[g]) gmax = gval[g];
            }
            if (gmax == 0)
            {
              memcpy(out, pix, sizeof(VngPixel));
              continue;
            }
            const int thold = gmin + (gmax >> 1);
            const int color = fcol(r, col);
            int num = 0;
            for (g = 0; g < 8; ++g, ip += 2)
            {
              if (gval[g] <= thold)
              {
                for (int c = 0; c < colors; ++c)
                  if (c == color && ip[1])
                    sum[c] += (pix[c] + pix[ip[1]]) >> 1;
                  else
                    sum[c] += pix[ip[0] + c];
                ++num;
              }
            }
            for (int c = 0; c < colors; ++c)
            {
              int value = pix[color];
              if (c != color) value += (sum[c] - sum[color]) / num;
              out[c] = CLIP(value);
            }
          }
        }
        // 这四行仍是原始双线性结果；下一批不能从已写回的 image 重读。
        memmove(source, source + size_t(count) * width, 4 * rowBytes);
      }
      return;
    }
  }
#endif
