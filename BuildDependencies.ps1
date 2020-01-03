<#
.SYNOPSIS
    Builds a project and all projects in its dependency tree through references.

.DESCRIPTION
    Builds a project and all projects in its dependency tree through references.

    This script parses the given project for all references that contain the
    specified keyword. Then search in the source repository under the folder and
    subfolders given by the base path for the projects producing the referenced assemblies.

.PARAMETER ProjectFile
    The given project whose references are analyzed.

.PARAMETER BasePath
    The path to the base folder in the source repository where search
    starts (in this folder and recursively in subfolders).

.PARAMETER Restore
    If specified, runs nuget package restore prior to building each project.

.PARAMETER Resume
    If present, resume the build run from where it stopped last time

.PARAMETER Keyword
    The keyword to search in the references. This is typically a keyword in the
    path to the referenced assemblies. This serves to effectively exclude those
    references that do not have producing projects in the source repository. For
    example, the .NET assemblies System.* .

    If not specified, all references are searched.

.PARAMETER DryRun
    Don't actually build the project and its dependencies, but just analyze and
    list its dependency projects which would be built.

.PARAMETER BuildArgs
    [string] The arguments passed "as-is" to build tool.

.INPUTS
    None.

.OUTPUTS
    None.

.EXAMPLE
    BuildDependencies.ps1 myproject.csproj c:\repo\src\dev

.EXAMPLE
    BuildDependencies.ps1 myproject.csproj c:\repo\src\dev -Restore -BuildArgs "-c"

.EXAMPLE
    BuildDependencies.ps1 myproject.csproj c:\repo\src\dev -Restore -Keyword "dev"
#>

[CmdletBinding()]
param (
    [parameter(Mandatory = $true, Position = 0)]
    [string] $projectFile,
    [parameter(Mandatory = $true, Position = 1)]
    [string[]] $basePath,
    [parameter(Mandatory = $false)]
    [switch] $restore,
    [parameter(Mandatory = $false)]
    [switch] $dryRun,
    [parameter(Mandatory = $false)]
    [switch] $resume,
    [parameter(Mandatory = $false)]
    [string] $keyword = $null,
    [parameter(Mandatory = $false)]
    [string] $buildArgs = $null
)


<#
.SYNOPSIS
    Returns a list of full paths to referenced assemblies matching the keyword.
#>
function Get-Reference
{
    param (
        # the project file
        [string] $projectFile,
        # the keyword in the reference path to search, if present
        [string] $keyword
    )

    $referencePaths = New-Object System.Collections.Generic.List[string]
    if (-not $projectFile.EndsWith(".csproj", "OrdinalIgnoreCase")) {
        # if it's not a csproj, we have no idea on how to get its references.
        return $referencePaths
    }

    # Note: there could be two ways to reference an assembly in a project:
    #   1. use Include attribute to point to path-to-assembly; or
    #   2. use HintPath to point to path-to-assembly.

    $projAsXml = (Select-Xml -Path $projectFile -XPath /).Node
    # this seems to exccessively return a Reference node for each ItemGroup
    # even though there isn't one. Filter null references
    $references = $projAsXml.Project.ItemGroup.Reference |
        Where-Object { $_ -ne $null }

    if ($keyword) {
        Write-Debug "Filter references by keyword: $keyword"
        $references = $references |
            Where-Object { ($_.Include -and $_.Include.Contains($keyword)) -or`
                           ($_.HintPath -and $_.HintPath.Contains($keyword)) }
    }

    foreach ($ref in $references) {
        if ($ref.HintPath) {
            $referencePaths.Add($ref.HintPath)
        }
        elseif ($ref.Include) {
            $referencePaths.Add($ref.Include)
        }
        else {
            Write-Host -ForegroundColor Red "$projectFile`: Reference missing Include attribute."
        }
    }

    return $referencePaths
}

<#
.SYNOPSIS
    Returns the project file producing the given assembly.
#>
function Find-ProjectFile
{
    param (
        # assembly name
        [string] $assemblyName,
        # target framework moniker of the assembly
        [string] $targetFramework,
        # collection of project files where to search for the producing project
        [System.IO.FileInfo[]] $projectFiles,
        # hastable of reference mapping to producing project for all known assemblies
        [hashtable] $knownReferences
    )

    Write-Debug "Looking for project producing: $assemblyName. TargetFramework: '$targetframework'"

    # trims the ".dll" extension if it exists in the assembly name
    if ($assemblyName.EndsWith(".dll", "OrdinalIgnoreCase")) {
        $assemblyName = $assemblyName.Substring(0, $assemblyName.Length-4)
    }

    # if assembly has been resolved
    if ($knownReferences.ContainsKey($assemblyName)) {
        Write-Debug "Already found: $($knownReferences[$assemblyName])"
        return $knownReferences[$assemblyName]
    }

    # Note: $projectFiles is a collection of FileInfo
    foreach ($projFile in $projectFiles) {
        [xml] $xml = (Select-Xml -Path $projFile.FullName -XPath /).Node
        [string] $producedAssembly = $xml.Project.PropertyGroup.AssemblyName |
            Where-Object { $_ -ne $null}

        # this is rare
        [string] $ns = $xml.Project.xmlns
        if ($producedAssembly -and $producedAssembly.StartsWith('$(') -and $producedAssembly.EndsWith(')')) {
            $path = $producedAssembly.Substring(2, $producedAssembly.Length-3)
            if ($ns) {
                $producedAssembly = (Select-Xml -Xml $xml -XPath "/ns:Project//ns:$path" -Namespace @{ns=$ns}).Node.InnerText
            }
            else {
                $producedAssembly = (Select-Xml -Xml $xml -XPath "/Project//$path").Node.InnerText
            }
        }

        # if AssemblyName matches $assemblyName
        if ($producedAssembly -eq $assemblyName) {
            Write-Debug "Found: $($projFile.FullName)"
            # assembly name matches, but it's a vcxproj, etc.
            if (-not $projFile.FullName.EndsWith(".csproj", "OrdinalIgnoreCase")) {
                $knownReferences[$assemblyName] = $projFile.FullName
                return $projFile.FullName
            }

            # ensure the TargetFramework matches
            $targetFrameworksInProjFile = (Select-Xml -Xml $xml -XPath "/Project//TargetFramework | /Project//TargetFrameworks").Node.InnerText
            # $targetFrameworksInProjFile = $xml.Project.PropertyGroup.TargetFramework
            # if (-not $targetFrameworksInProjFile) {
            #     $targetFrameworksInProjFile = $xml.Project.PropertyGroup.TargetFrameworks
            # }

            if ($targetFrameworksInProjFile) {
                # if the project file defines TargetFramework, it must match the assembly's target framework.
                if (Test-TargetFramwork $targetFramework $targetFrameworksInProjFile) {
                    $knownReferences[$assemblyName] = $projFile.FullName
                    return $projFile.FullName
                }
                else {
                    Write-Debug "Mismatch TargetFramework: '$targetFrameworksInProjFile'"
                }
            }
            else {
                # legacy netfx or project without TargetFramework defined
                $knownReferences[$assemblyName] = $projFile.FullName
                return $projFile.FullName
            }
        }
    }

    # failed to find the project file matching the specified assembly
    Write-Host -ForegroundColor Yellow "$assemblyName has no project file"
    $knownReferences[$assemblyName] = $null
    return $null
}

<#
.SYNOPSIS
    Tests if the source TFMs has any TFM that matches the given target framework.
    We need this test because a netstandard assembly may be referenced in a
    netcore assembly.
#>
function Test-TargetFramwork
{
    param (
        # target framework moniker to be matched
        [string] $targetFramework,
        # list of source TFMs (semicolon-delimited)
        [string] $sourceTargetFrameworks
    )

    foreach ($tfm in $sourceTargetFrameworks.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries)) {
        # tfm examples: net48;netstandard2.0;netcoreapp2.2
        # the first 4 chars are good enough to categorize them
        $shortTargetFrameworkName = $tfm.Substring(0, 4)

        # a "standard" TFM can match any target framework
        if ($shortTargetFrameworkName -eq "nets") {
            return $true
        }
        elseif ($shortTargetFrameworkName -eq $targetFramework.Substring(0, 4)) {
            return $true
        }
    }

    return $false
}

<#
.SYNOPSIS
    Returns the path to nuget.exe.
#>
function Get-NugetTool
{
    if (Test-Path env:NUGET_TOOL) {
        # use the environment variable if it is specified
        return $env:NUGET_TOOL
    }
    else {
        # return the path to nuget.exe if it is in the env:PATH
        $nugetTool = "nuget.exe"
        $nugetTool = Get-Command $nugetTool -ErrorAction SilentlyContinue
        if ($nugetTool) {
            return $nugetTool.Path
        }
        return $null
    }
}

<#
.SYNOPSIS
    Returns a collection of projects within the folders under the specified base
    path. This project collection will serve as the collection where to search for
    the project mapping to a specified assembly.
#>
function Get-ProjectCollection
{
    param (
        [string[]] $basePath
    )

    $projectExtensions = @(".csproj", ".vcxproj", "vcproj")
    $searchFilter = "*.*proj"

    Write-Host -ForegroundColor Cyan "Searching dependency projects in '$basePath'"
    $projectCollection = Get-ChildItem -Path $basePath -Filter $searchFilter -Recurse |
        Where-Object { $_.Extension -in $projectExtensions }
    Write-Host -ForegroundColor Cyan "Total number of projects to search:" $($projectCollection.Count)

    return $projectCollection
}

<#
.SYNOPSIS
    Returns the absolute path for the given relative path.
#>
function Get-AbsolutePath
{
    param (
        [string] $path
    )

    if (-not [System.IO.Path]::IsPathRooted($path)) {
        # non-rooted path is considered to be relative to current directory.
        $path = [System.IO.Path]::Combine((Get-Location).Path, $path)
    }

    # Note: rooted path can still be a relative path, e.g. c:myfile.txt.
    #       we just simply exclude this case.
    return [System.IO.Path]::GetFullPath($path)
}

<#
.SYNOPSIS
    Reads the resume file and prepares a project list for resuming build run.
#>
function Get-ResumeList
{
    param (
        [string] $resumeFile
    )

    if (Test-Path -Path $resumeFile -PathType Leaf) {
        $projects = New-Object System.Collections.Generic.List[string]
        foreach ($line in [System.IO.File]::ReadLines($resumeFile)) {
            # skip empty lines (if any)
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $projects.Add($line)
            }
        }
        return $projects
    }

    # resume file does not exist
    return $null
}

<#
#>
function Get-DependencyList
{
    param (
        # the project file whose reference dependency list is retrieved
        [string]   $projectFile,
        # the base paths to folders where projects for reference dependencis are searched
        [string[]] $basePath,
        # the keyword - only the references matching the keyword are retrieved
        [string]   $keyword
    )

    # use absolute path
    $projectFile = Get-AbsolutePath $projectFile
    $projectCollection = Get-ProjectCollection $basePath

    $dependencyProjects = New-Object System.Collections.Generic.List[string]
    $knownReferences = @{}

    # use a queue for breadth-first search
    $queue = New-Object System.Collections.Generic.LinkedList[string]
    $queue.AddLast($projectFile) | Out-Null

    while ($queue.Count -gt 0) {
        $projFile = $queue.First.Value
        $queue.RemoveFirst()

        Write-Debug "Searching dependencies on $projFile"

        # if the project file was added already, move it to the top of the list.
        if ($dependencyProjects.Contains($projFile)) {
            $dependencyProjects.Remove($projFile) | Out-Null
        }
        $dependencyProjects.Add($projFile)

        # consider only single-target projects
        # do not dig further if it's a legacy netfx or a vcxproj project
        $targetFramework = (Select-Xml -XPath "/Project//TargetFramework" -Path $projFile).Node.InnerText
        if (-not $targetFramework) {
            if ($projFile.EndsWith(".csproj", "OrdinalIgnoreCase")) {
                # SDK-style project shouldn't reference binary built from a legacy
                # netfx project in this repo.
                Write-Host -ForegroundColor Red "$projFile`: is a legacy netfx project."
            }
            continue
        }

        $references = Get-Reference $projFile $keyword
        foreach ($ref in $references) {
            # the $ref may not be a valid file path (e.g. if it contains msbuild properties)
            $refAssemblyName = $ref.Substring($ref.LastIndexOf("\")+1)
            $refProjFile = Find-ProjectFile $refAssemblyName $targetFramework $projectCollection $knownReferences
            if ($refProjFile) {
                # there is chance that the project is already in queue
                $positionInQueue = $queue.Find($refProjFile)
                if ($positionInQueue) {
                    # Write-Host "Queue already contains $refProjFile"
                    $queue.Remove($positionInQueue)
                }
                $queue.AddLast($refProjFile) | Out-Null
            }
        }

        if ($references.Count -eq 0) {
            Write-Debug "Found no reference dependencies."
        }
        else {
            Write-Debug "Found $($references.Count) reference dependencies."
        }
    }

    $dependencyProjects.Reverse()
    return $dependencyProjects
}

function Build-DependencyList
{
    param (
        # list of dependency projects to build
        [System.Collections.Generic.List[string]] $dependencyProjects,
        # arguments for build command
        [string] $buildArgs,
        # if present, run nuget restore before building the project
        [Parameter(Mandatory = $false)]
        [switch] $restore,
        # path to nuget tool (nuget.exe)
        [Parameter(Mandatory = $false)]
        [string] $nugetTool,
        # alternative command to get the project's external dependency binaries
        [Parameter(Mandatory = $false)]
        [string] $alterRestoreCommand,
        [Parameter(Mandatory = $true)]
        [string] $resumeFile

    )

    # cache current location for restoring from build failures
    $originalLocation = Get-Location

    [bool] $buildSucceeded = $true
    for ($i = 0; $i -lt $dependencyProjects.Count; $i++) {
        $project = $dependencyProjects[$i]
        $dir = [System.IO.Path]::GetDirectoryName($project)
        $file = [System.IO.Path]::GetFileName($project)

        Write-Host -ForegroundColor Cyan "Pushing to $dir"
        Write-Host -ForegroundColor Cyan "Building $file. Build Arguments: $buildArgs"
        Set-Location -Path $dir

        if ($restore.IsPresent) {
            if ($project.EndsWith(".csproj", "OrdinalIgnoreCase")) {
                Write-Host "Running cmd.exe /c $nugetTool restore `"$project`""
                & cmd.exe /c $nugetTool restore "$project"
            }
            else {
                Write-Host "Running $alterRestoreCommand"
                & $alterRestoreCommand
            }
        }

        $args = $buildArgs.Trim().Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
        Write-Host "Running build.cmd with args: '$args'"
        & build.cmd $args

        if (Test-Path -Path "build*.err" -PathType Leaf) {
            Write-Host -ForegroundColor Red "Build failed in `"$dir`""
            $buildSucceeded = $false
            $dependencyProjects.RemoveRange(0, $i)
            break
        }
    }

    Set-Location $originalLocation

    if ($buildSucceeded) {
        if (Test-Path -Path $resumeFile -PathType Leaf) {
            Remove-Item $resumeFile
        }
    }
    else {
        $dependencyProjects | Out-File $resumeFile
    }
}

################################################################################
# Main script entry point
################################################################################

# asking for confirmation for each Write-Debug output is quite annoying
if ($PSBoundParameters['Debug']) {
    $DebugPreference = 'Continue'
}

if ($restore.IsPresent) {
    $nuget = Get-NugetTool
    if (-not $nuget) {
        Write-Host -ForegroundColor Red "Restore option is specified but nuget tool is not available."
        Write-Host -ForegroundColor Red "Make sure env:NUGET_TOOL is set or nuget tool is accessible through env:PATH."
        exit
    }
}

$resumeFile = ".\build.deps.txt"

if ($resume.IsPresent) {
    Write-Debug "Resuming dependency list from $resumeFile"
    $dependencyProjects = Get-ResumeList $resumeFile
    if (-not $dependencyProjects) {
        Write-Host -ForegroundColor Red "$resumeFile is required to resume build run."
        exit
    }
}
else {
    $watchstart = Get-Date
    Write-Debug "Getting dependency list for project: $projectFile"
    $dependencyProjects = Get-DependencyList $projectFile $basePath $keyword
    $watchend = Get-Date
    $timetaken = ([TimeSpan]($watchend-$watchstart)).TotalMinutes
    Write-Host "Total time to complete search: $timetaken minutes."
}

Write-Host -ForegroundColor Cyan "Building the following projects in list order:"
$dependencyProjects

# exit the script if its a dry-run
if ($dryRun.IsPresent) {
    if (-not $resume.IsPresent) {
        $dependencyProjects | Out-File $resumeFile
    }
    exit
}

if ($restore.IsPresent) {
    $alterRestoreCommand = "getdeps.exe"
    Write-Debug "Buiding dependency list with: $buildArgs -restore -nugetTool $nuget -alterRestoreCommand $alterRestoreCommand -resumeFile $resumeFile"
    Build-DependencyList $dependencyProjects $buildArgs -restore -nugetTool $nuget -alterRestoreCommand $alterRestoreCommand -resumeFile $resumeFile
}
else {
    Write-Debug "Buiding dependency list with: $buildArgs -resumeFile $resumeFile"
    Build-DependencyList $dependencyProjects $buildArgs -resumeFile $resumeFile
}
