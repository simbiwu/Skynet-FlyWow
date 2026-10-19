--- 测试宿主根与进程工作目录不同，确保模块登记使用显式 root_path。
return
{
    patch_root = "./third_party/skynet-flywow/build/hotupgrade-tests/patches",
    root_path = "./third_party/skynet-flywow/build/hotupgrade-tests/host",
    service_dir = "service",
}
