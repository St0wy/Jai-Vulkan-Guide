#if OS == .WINDOWS {
    #load "generated_windows.jai";
} else #if OS == .LINUX {
    #load "generated_linux.jai";
}
