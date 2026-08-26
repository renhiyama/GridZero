#!/usr/bin/env python3
"""Idempotent applier for flutter_lite_camera 0.1.0 RestartCapture patch."""
import pathlib, re
base = pathlib.Path.home() / ".pub-cache/hosted/pub.dev/flutter_lite_camera-0.1.0"
h = base / "linux/include/Camera.h"
cpp = base / "linux/CameraLinux.cpp"
if not h.exists():
    print(f"skip: {h} not found")
    exit(0)
ht = h.read_text()
if "RestartCapture" not in ht:
    old = "    std::vector<MediaTypeInfo> ListSupportedMediaTypes();\n    FrameData CaptureFrame();\n    bool SetResolution(int width, int height);"
    new = "    std::vector<MediaTypeInfo> ListSupportedMediaTypes();\n    FrameData CaptureFrame();\n    bool SetResolution(int width, int height);\n\n    // GRIDZERO PATCH (see CameraLinux.cpp SetResolution): STREAMOFF ->\n    // S_FMT -> requeue -> STREAMON, since VIDIOC_S_FMT returns EBUSY while\n    // the stream Open() left running is active.\n    bool RestartCapture();"
    if old in ht:
        h.write_text(ht.replace(old, new))
        print("Camera.h patched")
    else:
        print("Camera.h mismatch, manual inspect")
else:
    print("Camera.h already patched")

ct = cpp.read_text()
if "bool Camera::RestartCapture()" not in ct:
    # Insert before SetResolution
    marker = "bool Camera::SetResolution(int width, int height)"
    impl = "// GRIDZERO PATCH: Open() leaves STREAMON active and VIDIOC_S_FMT fails with\n// EBUSY while streaming, so renegotiating a resolution needs a full\n// stop -> set -> requeue -> restart cycle. Upstream only did the S_FMT.\nbool Camera::RestartCapture()\n{\n    for (unsigned int i = 0; i < bufferCount; ++i)\n    {\n        struct v4l2_buffer buf;\n        memset(&buf, 0, sizeof(buf));\n        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;\n        buf.memory = V4L2_MEMORY_MMAP;\n        buf.index = i;\n        if (ioctl(fd, VIDIOC_QBUF, &buf) < 0) { perror(\"Error requeuing buffer\"); return false; }\n    }\n    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;\n    return ioctl(fd, VIDIOC_STREAMON, &type) >= 0;\n}\n\nbool Camera::SetResolution(int width, int height)"
    if marker in ct:
        ct2 = ct.replace(marker, impl)
        # Also need to patch SetResolution body: add StopCaptureLoop/StopCapture before S_FMT and RestartCapture after
        old_body = "    struct v4l2_format fmt;\n    memset(&fmt, 0, sizeof(fmt));\n    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;"
        new_body = "    struct v4l2_format fmt;\n    memset(&fmt, 0, sizeof(fmt));\n    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;"
        # Hard patch: replace the first ioctl S_FMT block with full cycle
        # For brevity, overwrite the whole SetResolution with known-good version from PATCHES.md
        # Re-read patched cpp from repo's patch file
        cpp.write_text(ct2)
        print("CameraLinux.cpp RestartCapture inserted (manual body patch may be needed, check)")
    else:
        print("CameraLinux.cpp marker not found")
else:
    print("CameraLinux.cpp already patched")

# Now ensure SetResolution has the STREAMOFF cycle
ct = pathlib.Path(cpp).read_text()
if "StopCaptureLoop();" not in ct:
    print("WARN: SetResolution body not fully patched — apply flutter_lite_camera_linux.patch manually")
else:
    print("CameraLinux.cpp body patched")
