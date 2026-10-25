#!/usr/bin/env python3
"""Independent binary64 reference for one-pixel atmospheric model boundary cases.

For a one-pixel image both minimum and guided filters reduce to their input;
this directly checks the model constants, signed mode and gamut mapping.
Spatial behavior is covered separately by atmosphere_tests.cpp.
"""
import json
from pathlib import Path


def smooth(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def decode(x):
    return x / 12.92 if x <= .04045 else ((x + .055) / 1.055) ** 2.4


def encode(x):
    return x * 12.92 if x <= .0031308 else 1.055 * x ** (1 / 2.4) - .055


def reference(rgb, amount):
    if amount == 0:
        return rgb
    p = list(map(decode, rgb))
    y = p[1] + .2126 * (p[0] - p[1]) + .0722 * (p[2] - p[1])
    air = [min(.95, max(.1, .85 * y + .15 * c)) for c in p]
    t = max(.5, min(1, 1 - .85 * min(c / a for c, a in zip(p, air))))
    if amount < 0:
        haze = -amount * .45 * (.25 + .75 * (1 - t))
        result = [c + (a - c) * haze for c, a in zip(p, air)]
    else:
        protect = y / (y + .03) * (1 - .8 * smooth((y - .5) / .4)) * (1 - .75 * smooth((y - .08) / .22))
        effective = max(.5, 1 - amount * protect * (1 - t))
        delta = [(c - a) * (1 / effective - 1) for c, a in zip(p, air)]
        pressure = 0.0
        for c, d in zip(p, delta):
            if d > 0:
                pressure = max(pressure, d / (1 - c) if c < 1 else float("inf"))
            elif d < 0:
                pressure = max(pressure, -d / c if c > 0 else float("inf"))
        result = [c + d / (1 + pressure) for c, d in zip(p, delta)]
    return [encode(min(1, max(0, c))) for c in result]


if __name__ == "__main__":
    colors = [[x, x, x] for x in (0, .01, .18, .5, .99, 1)] + [[.8, .5, .3], [.45, .65, .9], [1, .1, 0]]
    fixture = {"fixture_id": "rawlab-atmosphere-v1-one-pixel-reference", "version": 1,
               "float_absolute_tolerance": 5e-6,
               "scope": "Independent binary64 atmospheric model on constant one-pixel input; no spatial quality claim.",
               "cases": [{"input": rgb, "dehaze": amount, "expected": reference(rgb, amount)}
                         for rgb in colors for amount in (-1, -.5, 0, .5, 1)]}
    Path(__file__).with_name("fixtures").joinpath("atmosphere-v1-reference.json").write_text(json.dumps(fixture, indent=2) + "\n")
