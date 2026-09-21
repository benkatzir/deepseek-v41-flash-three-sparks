# Reconstruct the tested source stack on the original ARM64 SGLang base.
# This is a new image; historical measurements do not qualify this build.
FROM lmsysorg/sglang@sha256:b4a4745fab5393dc0aca573fe754b86477f57691c9e971390b21102d3d94ebf9
USER root
WORKDIR /opt/dsv41
ENV PYTHONPATH=""
COPY src/mia-native/ /opt/dsv41/
RUN g++ -O2 -Wall -Wextra -Werror -std=c++17 -shared -fPIC -pthread adapter/row_store.cpp -o adapter/librow_store.so
COPY src/mia-native/runtime/flash_mla_sm120.py /sgl-workspace/sglang/python/sglang/kernels/ops/attention/flash_mla_sm120.py
RUN PYTHONPATH=/opt/dsv41/adapter python3 /opt/dsv41/tests/test_thinking_alias.py \
 && PYTHONPATH=/opt/dsv41/adapter python3 /opt/dsv41/tests/test_max_new_tokens.py \
 && PYTHONPATH=/opt/dsv41/adapter python3 /opt/dsv41/tests/test_loop_abort.py

COPY src/draft-padding /opt/dsv41-lab/draft
RUN DSV41_CANDIDATE_IMAGE_BUILD=1 python3 -S /opt/dsv41-lab/draft/apply_candidate.py --root /sgl-workspace/sglang/python --apply
COPY src/telemetry/payload /opt/dsv41-lab/telemetry
COPY src/telemetry/install_telemetry.py /opt/dsv41-lab/install_telemetry.py
RUN python3 -S /opt/dsv41-lab/install_telemetry.py
COPY src/compact-extra-prefill /opt/dsv41-lab/compact-extra-prefill
COPY src/compact-extra-install /opt/dsv41-lab/compact-extra-install
RUN DSV41_CANDIDATE_IMAGE_BUILD=1 python3 -S /opt/dsv41-lab/compact-extra-install/install.py --apply --root /sgl-workspace/sglang/python --adapter /opt/dsv41/adapter

# Exact previously GPU-tested ARM64 extensions, with full source in src/.
# Building a replacement library requires new component qualification.
COPY src/exl3-extension-transfer /opt/exl3-extension-transfer
COPY src/install_extension.py /opt/exl3-compact-build/install_extension.py
RUN python3 /opt/exl3-compact-build/install_extension.py
COPY src/exl3-overlay /opt/exl3-overlay
RUN python3 /opt/exl3-overlay/install.py
COPY src/warm-prefix /opt/warm-own-prefix
RUN python3 -S /opt/warm-own-prefix/install_observer.py
COPY src/cooperative/integration /opt/dsv41-coop-integration
COPY src/cooperative/component /opt/dsv41-coop-integration/component
COPY src/cooperative/library /opt/dsv41-coop-integration/library
COPY src/cooperative/proofs /opt/dsv41-coop-integration/proofs
RUN python3 -S /opt/dsv41-coop-integration/install.py
COPY src/target-k /opt/dsv41-target-routed-k
RUN DSV41_PUBLIC_RECONSTRUCTION=1 python3 -S /opt/dsv41-target-routed-k/install.py

ENV PYTHONPATH=/opt/dsv41/adapter \
    MODEL_PATH=/models/DeepSeek-V4.1-Flash STATE_PATH=/state \
    OFFLOAD_MODE=nvme DSV41_CACHE_GIB=0 \
    DSV41_EXL3_MAIN_EXPERTS=0 DSV41_EXL3_COOP_ABI3=0 \
    DSV41_EXPERIMENT_TARGET_ROUTED_K=6 DSV41_COMPACT_EXTRA_PREFILL=0
LABEL org.opencontainers.image.title="DeepSeek V4.1 Flash three-Spark public reconstruction" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later AND Apache-2.0 AND MIT" \
      dsv41.public.reconstruction="v1-not-the-historical-image"
EXPOSE 8888
HEALTHCHECK --interval=30s --timeout=30s --start-period=30m --retries=3 CMD ["python3", "-S", "/opt/dsv41/boot.py", "health"]
ENTRYPOINT ["python3", "-u", "/opt/dsv41/boot.py"]
CMD ["run"]
