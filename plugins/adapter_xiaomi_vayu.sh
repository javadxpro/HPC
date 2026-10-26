#!/system/bin/sh
# HPC-PLUGIN: name=adapter_xiaomi_vayu version=1 min_core=1.10 perms=env,cpu,gpu
#
# Device adapter: Xiaomi POCO X3 Pro / M2007J3SGI (codename: vayu)
# SoC: Snapdragon 865 (Kryo 585, 1+3+4 clusters), GPU: Adreno 650 (kgsl)
#
# This plugin is a reference implementation of the device-adapter
# pattern. It only acts when the codename matches, registers
# device-specific knowledge, and exposes vendor controls that the
# generic discovery does not name. Everything it exposes still passes
# the core validation/protection/change-log pipeline.

_adapter_vayu_ok() {
    [ "$(getprop ro.product.device 2>/dev/null)" = "vayu" ]
}

adapter_xiaomi_vayu_init() {
    _adapter_vayu_ok || return 0
    km_plugin_register env.soc "SoC (adapter: vayu)" "-" "info" "str" \
        "Qualcomm SM8250 (Snapdragon 865), 1x2.84+3x2.42+4x1.8 GHz - adapter-provided metadata" 2>/dev/null
    # kgsl on 865: the GPU busy counter and clock are the reliable knobs;
    # devfreq governor support is kernel-build dependent, so only
    # register the clock control when the node actually exists.
    if [ -f /sys/class/kgsl/kgsl-3d0/gpuclk ]; then
        km_plugin_register plugin.vayu_gpu_clock "Adreno 650 GPU clock" "/sys/class/kgsl/kgsl-3d0/gpuclk" "info" "int" \
            "kHz; 0 = clocked down to sleep (normal when idle)" 2>/dev/null
    fi
    log_info "adapter active: xiaomi_vayu (SM8250/Adreno 650)"
    return 0
}

# monitor extra: expose adapter info in the JSON the UI can render
km_mon_adapter_xiaomi_vayu_extra() {
    _adapter_vayu_ok || return 0
    printf '{"adapter":"xiaomi_vayu","soc":"SM8250 (SD865)","gpu":"Adreno 650"}'
}

adapter_xiaomi_vayu_init
return 0
