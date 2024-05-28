Write-Output "Building compute shaders"
foreach ($computeShader in Get-ChildItem -Recurse -Filter "*.comp")
{
    Write-Output "Building $computeShader ..."
    $buildCommand = "glslc $computeShader -o $( $computeShader ).spv"
    Invoke-Expression $buildCommand
}

Write-Output ""
Write-Output "Building fragment shaders"
foreach ($fragmentShader in Get-ChildItem -Recurse -Filter "*.frag")
{
    Write-Output "Building $fragmentShader ..."
    $buildCommand = "glslc $fragmentShader -o $( $fragmentShader ).spv"
    Invoke-Expression $buildCommand
}

Write-Output ""
Write-Output "Building vertex shaders"
foreach ($vertexShader in Get-ChildItem -Recurse -Filter "*.vert")
{
    Write-Output "Building $vertexShader ..."
    $buildCommand = "glslc $vertexShader -o $( $vertexShader ).spv"
    Invoke-Expression $buildCommand
}
