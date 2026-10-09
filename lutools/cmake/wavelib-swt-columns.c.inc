/* Keep wavelib's tap order and periodic extension, but traverse columns by row
 * so neighboring pixels share cache lines and the inner loop can vectorize. */
static void rawlab_swt_columns(int dilation, double *input, int rows, int cols,
    double *low_filter, double *high_filter, int taps, double *low, double *high) {
    if (rows % 2 || dilation * taps > rows) {
        for (int x = 0; x < cols; ++x)
            swt_per_stride(dilation, input + x, rows, low_filter, high_filter,
                taps, low + x, rows, high + x, cols, cols);
        return;
    }
    for (int y = 0; y < rows; ++y) {
        double *a = low + y * cols, *d = high + y * cols;
        memset(a, 0, cols * sizeof(double));
        memset(d, 0, cols * sizeof(double));
        for (int tap = 0; tap < taps; ++tap) {
            int source = y + dilation * taps / 2 - tap * dilation;
            if (source < 0) source += rows;
            else if (source >= rows) source -= rows;
            const double *line = input + source * cols;
            const double lo = low_filter[tap], hi = high_filter[tap];
            for (int x = 0; x < cols; ++x) {
                a[x] += lo * line[x];
                d[x] += hi * line[x];
            }
        }
    }
}
