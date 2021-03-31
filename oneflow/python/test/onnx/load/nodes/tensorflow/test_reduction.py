"""
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"""
import tensorflow as tf

from oneflow.python.test.onnx.load.util import load_tensorflow2_module_and_check

def test_reduce_mean(test_case):
    class Net(tf.keras.Model):
        def call(self, x):
            return tf.math.reduce_mean(x)

    load_tensorflow2_module_and_check(test_case, Net)


def test_reduce_mean_axis(test_case):
    class Net(tf.keras.Model):
        def call(self, x):
            return tf.math.reduce_mean(x, axis=1)

    load_tensorflow2_module_and_check(test_case, Net)


def test_reduce_mean_axis_keepdim(test_case):
    class Net(tf.keras.Model):
        def call(self, x):
            return tf.math.reduce_mean(x, axis=3, keepdims=True)

    load_tensorflow2_module_and_check(test_case, Net)

from absl import app
from absl.testing import absltest

test_case = absltest.TestCase
test_reduce_mean_axis_keepdim(test_case)