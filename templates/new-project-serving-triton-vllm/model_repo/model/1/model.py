# Triton Python backend for vLLM.
# Runs inside nvcr.io/nvidia/tritonserver:*-vllm-python-py3.
# Compatible with LiteLLM's triton provider:
#   model: triton/model
#   api_base: http://<svc>:8000
#
# Input tensors:
#   text_input          (BYTES, [1,1]) — prompt string
#   stream              (BOOL,  [1,1]) — ignored; non-streaming only
#   sampling_parameters (BYTES, [1,1]) — JSON: {"max_tokens":N, "temperature":F, ...}
# Output tensor:
#   text_output         (BYTES, [-1]) — generated text
import asyncio
import json
import os
import threading

import numpy as np
import triton_python_backend_utils as pb_utils
from vllm import AsyncLLMEngine, SamplingParams
from vllm.engine.arg_utils import AsyncEngineArgs
from vllm.lora.request import LoRARequest


class TritonPythonModel:
    def initialize(self, args):
        # Dedicated event loop in a background thread for async vLLM engine.
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._loop.run_forever, daemon=True)
        self._thread.start()

        engine_args = AsyncEngineArgs(
            model="{{HF_MODEL_ID}}",
            enable_lora=os.path.exists("/adapter"),
            max_lora_rank=16,
            dtype="bfloat16",
            gpu_memory_utilization=0.90,
            max_model_len=2048,
            disable_log_requests=True,
        )
        future = asyncio.run_coroutine_threadsafe(
            self._init_engine(engine_args), self._loop
        )
        future.result(timeout=600)

        self.served_model_name = "{{SERVED_MODEL_NAME}}"
        self.lora_request = (
            LoRARequest(self.served_model_name, 1, "/adapter")
            if os.path.exists("/adapter")
            else None
        )

    async def _init_engine(self, engine_args):
        self.engine = AsyncLLMEngine.from_engine_args(engine_args)

    def execute(self, requests):
        responses = []
        for request in requests:
            text_input = (
                pb_utils.get_input_tensor_by_name(request, "text_input")
                .as_numpy()
                .flatten()[0]
                .decode("utf-8")
            )

            sp_tensor = pb_utils.get_input_tensor_by_name(request, "sampling_parameters")
            if sp_tensor is not None:
                sp_json = sp_tensor.as_numpy().flatten()[0].decode("utf-8")
                sp_dict = json.loads(sp_json) if sp_json.strip() else {}
            else:
                sp_dict = {}

            sampling_params = SamplingParams(
                temperature=float(sp_dict.get("temperature", 0.7)),
                max_tokens=int(sp_dict.get("max_tokens", 512)),
                top_p=float(sp_dict.get("top_p", 1.0)),
                stop=sp_dict.get("stop") or None,
            )

            future = asyncio.run_coroutine_threadsafe(
                self._generate(text_input, sampling_params), self._loop
            )
            try:
                output_text = future.result(timeout=300)
            except Exception as e:
                output_text = f"[ERROR] {e}"

            out_tensor = pb_utils.Tensor(
                "text_output",
                np.array([output_text.encode("utf-8")], dtype=object),
            )
            responses.append(pb_utils.InferenceResponse(output_tensors=[out_tensor]))
        return responses

    async def _generate(self, prompt, sampling_params):
        request_id = f"req-{id(prompt)}-{id(sampling_params)}"
        final_output = None
        async for output in self.engine.generate(
            prompt, sampling_params, request_id, lora_request=self.lora_request
        ):
            final_output = output
        if final_output is None:
            return ""
        return final_output.outputs[0].text

    def finalize(self):
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(timeout=10)
        if hasattr(self, "engine"):
            del self.engine
