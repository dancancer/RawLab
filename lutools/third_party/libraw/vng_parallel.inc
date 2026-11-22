/*
 * VNG pixel arithmetic derived from LibRaw 0.22.2 misc_demosaic.cpp.
 * Copyright 2019-2025 LibRaw LLC (info@libraw.org).
 * Available under LGPL-2.1 or CDDL-1.0, as with the original LibRaw source.
 */
#if defined(LIBRAW_USE_OPENMP)
  const unsigned vngWorkers = static_cast<unsigned>(std::max(1, omp_get_max_threads()));
#elif defined(__APPLE__) && !defined(RAWLAB_VNG_FORCE_STD_THREAD)
  const unsigned vngWorkers = std::min<unsigned>(std::max(1u, std::thread::hardware_concurrency()), 8u);
#else
  const unsigned vngWorkers = std::min<unsigned>(std::max(1u, std::thread::hardware_concurrency()), 8u);
#endif
  if (filters > 1000 && vngWorkers > 1)
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
        // 回调只在调用线程运行；取消异常不跨越并行区域。
        RUN_CALLBACK(LIBRAW_PROGRESS_INTERPOLATE, (first - 2) / 256 + 1,
                     ((height - 3) / 256) + 1);
        memcpy(source + size_t(4) * width, image + size_t(first + 2) * width,
               size_t(count) * rowBytes);
        const auto processRow = [&](int r) {
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
        };
#if defined(LIBRAW_USE_OPENMP)
#pragma omp parallel for schedule(static)
        for (int r = first; r < first + count; ++r)
        {
          processRow(r);
        }
#elif defined(__APPLE__) && !defined(RAWLAB_VNG_FORCE_STD_THREAD)
        if (count <= 1)
        {
          for (int r = first; r < first + count; ++r) processRow(r);
        }
        else
        {
          struct VngDispatchContext {
            const decltype(processRow) *fn;
            int firstRow;
          } ctx{&processRow, first};
          dispatch_apply_f(
              static_cast<size_t>(count),
              dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
              &ctx,
              [](void *rawCtx, size_t idx) {
                const auto *c = static_cast<const VngDispatchContext *>(rawCtx);
                (*c->fn)(c->firstRow + static_cast<int>(idx));
              });
        }
#else
        if (count <= 1)
        {
          for (int r = first; r < first + count; ++r) processRow(r);
        }
        else
        {
          const unsigned rowWorkers = std::min<unsigned>(vngWorkers, static_cast<unsigned>(count));
          std::atomic<int> nextOffset{0};
          std::vector<std::thread> pool;
          pool.reserve(rowWorkers - 1);
          const auto worker = [&]() {
            for (;;)
            {
              const int offset = nextOffset.fetch_add(1, std::memory_order_relaxed);
              if (offset >= count) break;
              processRow(first + offset);
            }
          };
          for (unsigned t = 1; t < rowWorkers; ++t) pool.emplace_back(worker);
          worker();
          for (auto &th : pool) th.join();
        }
#endif
        // 这四行仍是原始双线性结果；下一批不能从已写回的 image 重读。
        memmove(source, source + size_t(count) * width, 4 * rowBytes);
      }
      return;
    }
  }
