# Triton Python backend for TRT-LLM.
# Runs inside nvcr.io/nvidia/tritonserver:*-trtllm-python-py3.
# Compatible with LiteLLM's triton provider:
#   model: triton/model
#   api_base: http://<svc>:8000
#
# Engine at /engine/ is baked in at image build time (GPU-arch specific).
# Input tensors:
#   text_input          (BYTES, [1,1]) — prompt string
#   stream              (BOOL,  [1,1]) — ignored; non-streaming only
#   sampling_parameters (BYTES, [1,1]) — JSON: {"max_tokens":N, "temperature":F, ...}
# Output tensor:
#   text_output         (BYTES, [-1]) — generated text
import json

import numpy as np
import triton_python_backend_utils as pb_utils
from tensorrt_llm import LLM
from tensorrt_llm.llmapi import SamplingParams as TRTSamplingParams


class TritonPythonModel:
    def initialize(self, args):
        self.served_model_name = "{{SERVED_MODEL_NAME}}"
        self.llm = LLM(model="/engine")

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

            sampling_params = TRTSamplingParams(
                temperature=float(sp_dict.get("temperature", 0.7)),
                max_tokens=int(sp_dict.get("max_tokens", 512)),
                top_p=float(sp_dict.get("top_p", 1.0)),
            )

            try:
                outputs = list(self.llm.generate([text_input], sampling_params))
                output_text = outputs[0].outputs[0].text if outputs else ""
            except Exception as e:
                output_text = f"[ERROR] {e}"

            out_tensor = pb_utils.Tensor(
                "text_output",
                np.array([output_text.encode("utf-8")], dtype=object),
            )
            responses.append(pb_utils.InferenceResponse(output_tensors=[out_tensor]))
        return responses

    def finalize(self):
        if hasattr(self, "llm"):
            del self.llm
