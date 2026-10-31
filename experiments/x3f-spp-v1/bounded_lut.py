"""有界三线性颜色响应实验；节点约束防止多项式外推越过显示范围。"""

from itertools import product
import numpy as np
from calibration import srgb_encode


def compress_scene(scene):
    scene = np.asarray(scene, dtype=np.float64)
    return np.sign(scene) * srgb_encode(np.abs(scene) / (1 + np.abs(scene)))


def weights(points, axis):
    points = np.asarray(points, dtype=np.float64).reshape(-1, 3)
    axis = np.asarray(axis, dtype=np.float64)
    if len(axis) < 2 or np.any(np.diff(axis) <= 0) or not np.all(np.isfinite(points)):
        raise ValueError("Invalid interpolation coordinates")
    points = np.clip(points, axis[0], axis[-1])
    lo = np.clip(np.searchsorted(axis, points, side="right") - 1, 0, len(axis) - 2)
    fraction = (points - axis[lo]) / (axis[lo + 1] - axis[lo])
    indices, factors = [], []
    for corner in product((0, 1), repeat=3):
        offset = np.array(corner)
        xyz = lo + offset
        indices.append((xyz[:, 0] * len(axis) + xyz[:, 1]) * len(axis) + xyz[:, 2])
        factors.append(np.prod(np.where(offset, fraction, 1 - fraction), axis=1))
    return np.column_stack(indices), np.column_stack(factors)


def interpolate(points, axis, nodes):
    indices, factors = weights(points, axis)
    return np.sum(np.asarray(nodes)[indices] * factors[..., None], axis=1)


def fit(points, target, axis, point_weight, smoothness, prior):
    indices, factors = weights(points, axis)
    target = np.asarray(target, dtype=np.float64).reshape(-1, 3)
    point_weight = np.asarray(point_weight, dtype=np.float64)
    count = len(axis) ** 3
    prior = np.asarray(prior, dtype=np.float64).reshape(count, 3)
    if len(target) != len(indices) or point_weight.shape != (len(indices),) or smoothness <= 0:
        raise ValueError("Invalid fitting samples")
    if np.any(point_weight < 0) or not np.any(point_weight > 0) or not np.all(np.isfinite(target)):
        raise ValueError("Invalid fitting weights or targets")
    gram = np.zeros((count, count))
    rhs = np.zeros((count, 3))
    for i in range(8):
        weighted = factors[:, i] * point_weight
        for channel in range(3):
            rhs[:, channel] += np.bincount(indices[:, i], weights=weighted * target[:, channel], minlength=count)
        for j in range(8):
            pair = indices[:, i] * count + indices[:, j]
            gram += np.bincount(pair, weights=weighted * factors[:, j], minlength=count * count).reshape(count, count)

    # 平滑相对一维先验的残差，未被样本覆盖的节点保留可解释的响应。
    grid = np.arange(count).reshape((len(axis),) * 3)
    edges = [(np.take(grid, range(len(axis) - 1), axis=d).ravel(),
              np.take(grid, range(1, len(axis)), axis=d).ravel()) for d in range(3)]
    for first, second in edges:
        np.add.at(gram, (first, first), smoothness)
        np.add.at(gram, (second, second), smoothness)
        np.add.at(gram, (first, second), -smoothness)
        np.add.at(gram, (second, first), -smoothness)
        difference = smoothness * (prior[first] - prior[second])
        np.add.at(rhs, first, difference)
        np.add.at(rhs, second, -difference)
    ridge = smoothness / 10
    gram.flat[::count + 1] += ridge
    rhs += ridge * prior
    current = np.clip(np.linalg.solve(gram, rhs), 0, 1)
    extrapolated = current.copy()
    step = 1 / np.max(np.sum(np.abs(gram), axis=1))
    momentum = 1.0
    for _ in range(400):
        updated = np.clip(extrapolated - step * (gram @ extrapolated - rhs), 0, 1)
        if np.max(np.abs(updated - current)) < 1e-8:
            current = updated
            break
        next_momentum = (1 + np.sqrt(1 + 4 * momentum ** 2)) / 2
        extrapolated = updated + (momentum - 1) / next_momentum * (updated - current)
        current, momentum = updated, next_momentum
    return current


def monotone_prior(points, target, point_weight, axis):
    curves = []
    positions = np.linspace(axis[0], axis[-1], 257)
    for channel in range(3):
        bins = np.clip(np.searchsorted(positions, points[:, channel]) - 1, 0, 255)
        total = np.bincount(bins, weights=point_weight, minlength=256)
        sums = np.bincount(bins, weights=point_weight * target[:, channel], minlength=256)
        valid = np.flatnonzero(total > 0)
        # Pool adjacent violators；每项保存有序区间的权重和加权输出。
        blocks = []
        for index in valid:
            blocks.append([index, index, total[index], sums[index]])
            while len(blocks) > 1 and blocks[-2][3] / blocks[-2][2] > blocks[-1][3] / blocks[-1][2]:
                right = blocks.pop(); left = blocks.pop()
                blocks.append([left[0], right[1], left[2] + right[2], left[3] + right[3]])
        values = np.zeros(256)
        for start, end, mass, value in blocks:
            values[start:end + 1] = value / mass
        curves.append(np.interp(axis, (positions[:-1] + positions[1:])[valid] / 2,
                                values[valid], left=0, right=1))
    coordinates = np.meshgrid(*curves, indexing="ij")
    return np.clip(np.stack(coordinates, axis=-1).reshape(-1, 3), 0, 1)
