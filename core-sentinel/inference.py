"""
SpecterEngine Neural Sentinel Inference Engine
Vectorized composite anomaly scorer and sub-millisecond ONNX runtime execution handler.
Computes continuous threat metric:
S_t = alpha * (Delta_R / R_nominal) + beta * (grad_Slippage / sigma_hist) + gamma * (G_priority / G_bar)
"""

from __future__ import annotations

import os
import time
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Tuple, Dict, Any, Optional

import numpy as np

try:
    import onnxruntime as ort
    ONNX_RUNTIME_AVAILABLE = True
except ImportError:
    ort = None
    ONNX_RUNTIME_AVAILABLE = False

try:
    import onnx
    from onnx import helper, TensorProto
    ONNX_EXPORT_AVAILABLE = True
except ImportError:
    onnx = None
    ONNX_EXPORT_AVAILABLE = False

from config import CONFIG


@dataclass
class AnomalyScoreResult:
    threat_score: float
    is_anomaly: bool
    reserve_shift_ratio: float
    slippage_gradient_norm: float
    priority_gas_ratio: float
    inference_latency_ms: float
    engine_type: str


class SlidingWindowBuffer:
    """
    Thread-safe, vectorized circular buffer maintaining a 50-tick sliding window
    of high-frequency pool telemetry and mempool gas dynamics.
    """

    def __init__(self, capacity: int = 50):
        self.capacity = capacity
        self.lock = threading.Lock()

        # Preallocated contiguous memory buffers
        self.reserves_0 = np.zeros(capacity, dtype=np.float64)
        self.reserves_1 = np.zeros(capacity, dtype=np.float64)
        self.slippage_velocities = np.zeros(capacity, dtype=np.float64)
        self.priority_fees = np.zeros(capacity, dtype=np.float64)
        self.base_fees = np.zeros(capacity, dtype=np.float64)
        self.timestamps = np.zeros(capacity, dtype=np.float64)

        self.head: int = 0
        self.count: int = 0
        self.last_slippage: float = 0.0

    def append(
        self,
        reserve_0: float,
        reserve_1: float,
        slippage_velocity: float,
        priority_fee_gwei: float,
        base_fee_gwei: float,
        timestamp: float | None = None
    ) -> None:
        """
        Thread-safely appends state observations into circular buffer.
        """
        ts = timestamp if timestamp is not None else time.time()
        with self.lock:
            idx = self.head
            self.reserves_0[idx] = reserve_0
            self.reserves_1[idx] = reserve_1
            self.slippage_velocities[idx] = slippage_velocity
            self.priority_fees[idx] = priority_fee_gwei
            self.base_fees[idx] = base_fee_gwei
            self.timestamps[idx] = ts

            self.last_slippage = slippage_velocity
            self.head = (idx + 1) % self.capacity
            if self.count < self.capacity:
                self.count += 1

    def compute_window_statistics(self) -> Tuple[float, float, float, float]:
        """
        Computes rolling statistics over the active window.
        Returns:
            (sigma_slippage, mean_slippage, mean_priority_gas, mean_base_gas)
        """
        with self.lock:
            if self.count < 2:
                return 1.0, 1.0, 1.0, 1.0

            valid_slippage = self.slippage_velocities[:self.count]
            valid_p_fees = self.priority_fees[:self.count]
            valid_b_fees = self.base_fees[:self.count]

            sigma_slippage = float(np.std(valid_slippage))
            if sigma_slippage < 1e-4:
                sigma_slippage = 1.0

            mean_slippage = float(np.mean(valid_slippage))
            mean_p_fee = float(np.mean(valid_p_fees))
            if mean_p_fee < 1e-4:
                mean_p_fee = 1.0

            mean_b_fee = float(np.mean(valid_b_fees))
            if mean_b_fee < 1e-4:
                mean_b_fee = 1.0

            return sigma_slippage, mean_slippage, mean_p_fee, mean_b_fee


class AnomalyInferenceEngine:
    """
    Sub-millisecond composite threat inference engine.
    Supports native ONNX runtime (<0.05ms latency) with instant vectorized NumPy fallback.
    """

    def __init__(
        self,
        alpha: float = CONFIG.alpha_reserve,
        beta: float = CONFIG.beta_slippage,
        gamma: float = CONFIG.gamma_priority_gas,
        threshold: float = CONFIG.threat_threshold,
        model_path: Path | None = None
    ):
        self.alpha = alpha
        self.beta = beta
        self.gamma = gamma
        self.threshold = threshold
        self.model_path = model_path or CONFIG.onnx_model_path
        self.weights_vector = np.array([alpha, beta, gamma], dtype=np.float32).reshape(3, 1)

        self.buffer = SlidingWindowBuffer(capacity=CONFIG.sliding_window_depth)
        self.onnx_session: Optional[ort.InferenceSession] = None

        self._initialize_onnx()

    def _initialize_onnx(self) -> None:
        """
        Loads pre-compiled ONNX model or dynamically synthesizes it if missing.
        """
        if not ONNX_RUNTIME_AVAILABLE:
            return

        self.model_path.parent.mkdir(parents=True, exist_ok=True)

        if not self.model_path.exists() and ONNX_EXPORT_AVAILABLE:
            self._export_onnx_model(self.model_path)

        if self.model_path.exists():
            try:
                opts = ort.SessionOptions()
                opts.intra_op_num_threads = 1
                opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
                self.onnx_session = ort.InferenceSession(str(self.model_path), sess_options=opts)
            except Exception:
                self.onnx_session = None

    def _export_onnx_model(self, target_path: Path) -> None:
        """
        Dynamically synthesizes production-grade ONNX computation graph.
        """
        if not ONNX_EXPORT_AVAILABLE:
            return

        input_tensor = helper.make_tensor_value_info('input_features', TensorProto.FLOAT, [None, 3])
        output_tensor = helper.make_tensor_value_info('threat_score', TensorProto.FLOAT, [None, 1])

        weights_init = helper.make_tensor(
            'weights',
            TensorProto.FLOAT,
            [3, 1],
            self.weights_vector.flatten()
        )

        matmul_node = helper.make_node(
            'MatMul',
            inputs=['input_features', 'weights'],
            outputs=['threat_score'],
            name='ThreatScoreMatMul'
        )

        graph = helper.make_graph(
            [matmul_node],
            'SpecterAnomalyDetector',
            [input_tensor],
            [output_tensor],
            [weights_init]
        )

        opset = helper.make_opsetid('', 18)
        model = helper.make_model(graph, producer_name='SpecterEngine', opset_imports=[opset], ir_version=10)
        onnx.checker.check_model(model)
        onnx.save(model, str(target_path))

    def evaluate_threat(
        self,
        reserve_delta: float,
        nominal_reserve: float,
        slippage_velocity: float,
        priority_fee_gwei: float = 1.0,
        base_fee_gwei: float = 0.001
    ) -> AnomalyScoreResult:
        """
        Evaluates continuous anomaly score S_t over incoming telemetry tick.
        Target execution latency: < 3.0 ms (typical: < 0.05 ms).
        """
        t0 = time.perf_counter()

        sigma_slippage, mean_slippage, mean_p_gas, _ = self.buffer.compute_window_statistics()

        # Feature 1: Delta R / R_nominal
        norm_nominal = nominal_reserve if nominal_reserve > 0 else 1.0
        feature_reserve = float(abs(reserve_delta) / norm_nominal)

        # Feature 2: grad(Slippage) / sigma_historical
        # grad(Slippage) represents the surge relative to previous tick or mean
        grad_slippage = max(0.0, float(slippage_velocity - mean_slippage))
        feature_slippage = float(grad_slippage / (sigma_slippage + 1e-5))

        # Feature 3: Priority gas fee ratio (mempool urgency signal)
        feature_gas = float(priority_fee_gwei / (mean_p_gas + 1e-5))

        # Feature vector [1, 3]
        feature_matrix = np.array(
            [[feature_reserve, feature_slippage, feature_gas]],
            dtype=np.float32
        )

        # Inference Execution
        engine_type = "NUMPY_VECTORIZED"
        threat_score: float = 0.0

        if self.onnx_session is not None:
            try:
                outputs = self.onnx_session.run(
                    None,
                    {'input_features': feature_matrix}
                )
                threat_score = float(outputs[0][0][0])
                engine_type = "ONNX_RUNTIME"
            except Exception:
                threat_score = float(np.dot(feature_matrix[0], self.weights_vector.flatten()))
                engine_type = "NUMPY_FALLBACK"
        else:
            threat_score = float(np.dot(feature_matrix[0], self.weights_vector.flatten()))

        t1 = time.perf_counter()
        latency_ms = (t1 - t0) * 1000.0

        is_anomaly = (threat_score >= self.threshold)

        return AnomalyScoreResult(
            threat_score=threat_score,
            is_anomaly=is_anomaly,
            reserve_shift_ratio=feature_reserve,
            slippage_gradient_norm=feature_slippage,
            priority_gas_ratio=feature_gas,
            inference_latency_ms=latency_ms,
            engine_type=engine_type
        )
