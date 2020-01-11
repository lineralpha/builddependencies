<#
.SYNOPSIS
    Builds a project and all projects in its dependency tree through assembly references.

.DESCRIPTION
    This script builds the given project and all its dependency projects through
    the assembly references in the project files.

    It first parses the given project for all assembly references that match the
    specified keyword; then searches in the source repository (or a subfolder
    in the repository) speficied by the base path for projects producing the
    referenced assemblies. It recursively repeats the above process for each of
    the dependency projects until all referenced assemblies downward the dependency
    tree are resolved, and a dependency list of projects is generated. Finally,
    this script launches the build command to build the projects in the order of
    the dependency list.

.PARAMETER ProjectFile
    The given project whose assembly reference dependency tree is parsed and built.

.PARAMETER BasePath
    The full path to the source repository, or subfolders where search for dependency
    projects starts.

    Search happens in the BasePath folder and recursively its subfolders. If search
    only needs to happen in portion of the source repository, BasePath can point
    to the top folder of that portion. Multiple base paths can be specified if
    search in multiple locations is of the interest.

.PARAMETER Keyword
    If present, the keyword is used to match the assembly references during the
    search process.

    This is typically a keyword in the path to the referenced assemblies. References
    that do not match the keyword will be excluded from the search process, and
    thus will not be added to the dependency tree. This effectively serves to
    exclude those assembly references that do not have producing projects in the
    source repository. For example, third-party assemblies or assemblies produced
    from external repositories.

.PARAMETER DryRun
    If present, this script doesn't actually build the project and its dependency
    projects, but just analyzes and outputs its dependency projects which would
    be built otherwise.

.PARAMETER Resume
    If present, this script resumes the build run from the point where it stopped
    in previous run, without needing to re-parse the dependency tree.

    This can be useful and time-saving in the following two scenarios:
    1. If DryRun is specified in previous run, the dependency list is already
       generated. Launching a new run with Resume specified will just pick up and
       build the existing dependency list, without re-parsing the dependency tree.
    2. If previous run failed and exited at a project, relaunching this script will
       continue from the failed project after issue was resolved, without needing
       to re-parse or rebuild the entire dependency tree.

.PARAMETER Restore
    If present, this script runs nuget package restore prior to building each project.

    Nuget tool (nuget.exe) must be set through env:NUGET_TOOL or available via
    env:PATH. For projects that do not use nuget packages, alternative tool (or
    command) for getting external dependencies can be set via env:ALTER_NUGET_TOOL.

    If used, both env:NUGET_TOOL and env:ALTER_NUGET_TOOL must be set before launching
    the script.

.PARAMETER BuildArgs
    If present, these are build arguments passed "as-is" to the build command.

.INPUTS
    None.

.OUTPUTS
    None.

.EXAMPLE
    BuildDependencies.ps1 myproject.csproj c:\repo\src\dev -Keyword critical

    Build myproject.csproj in current location, search its dependency tree in
    folder c:\repo\src\dev, and dependency references must match keyword "critical".

.EXAMPLE
    BuildDependencies.ps1 myproject.csproj c:\repo\src\dev -DryRun

    Analyze but do not build myproject.csproj in current location, search its
    dependency tree in folder c:\repo\src\dev.

.EXAMPLE
    BuildDependencies.ps1 myproject.csproj c:\repo\src\dev -Resume

    Resume building myproject.csproj and its dependency tree from the point where
    the previous build run stopped. This command will not re-parse the project's
    dependency tree. Instead, it picks up and continues with whatever left from the
    previous build run.

.EXAMPLE
    BuildDependencies.ps1 myproject.csproj c:\repo\src\dev -Restore -BuildArgs "-c"

    Build myproject.csproj and its dependency tree. Run nuget restore before
    launching build command, and launch build command with argument "-c".
#>

[CmdletBinding()]
param (
    [parameter(Mandatory = $true, Position = 0)]
    [string] $ProjectFile,
    [parameter(Mandatory = $true, Position = 1)]
    [string[]] $BasePath,
    [parameter(Mandatory = $false)]
    [string] $Keyword = $null,
    [parameter(Mandatory = $false)]
    [switch] $DryRun,
    [parameter(Mandatory = $false)]
    [switch] $Resume,
    [parameter(Mandatory = $false)]
    [switch] $Restore,
    [parameter(Mandatory = $false)]
    [string] $BuildArgs = $null
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

    [xml] $xml = (Select-Xml -Path $projectFile -XPath /).Node
    # this seems to exccessively return a Reference node for each ItemGroup
    # even though there isn't one. Filter null references
    $references = $xml.Project.ItemGroup.Reference |
        Where-Object { $_ -ne $null }

    if ($keyword) {
        Write-Debug "Filter references by keyword: $keyword"
        # $pattern = [System.Text.RegularExpressions.Regex]::Escape($keyword)
        $pattern = "*$keyword*"
        $references = $references |
            Where-Object { ($_.Include -and $_.Include -like $pattern) -or`
                           ($_.HintPath -and $_.HintPath -like $pattern) }
        Write-Debug "$($references.Count) references matching keyword:"
    }

    foreach ($ref in $references) {
        if ($ref.HintPath) {
            Write-Debug $ref.HintPath
            $referencePaths.Add($ref.HintPath)
        }
        elseif ($ref.Include) {
            Write-Debug $ref.Include
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
        # target framework of the assembly
        [string] $targetFramework,
        # collection of project files where to search for the producing project
        [System.IO.FileInfo[]] $projectFiles,
        # hastable of reference mapping to producing project for all known assemblies
        [hashtable] $knownReferences
    )

    Write-Debug "Looking for project producing: $assemblyName. TargetFramework: '$targetframework'"
    $assemblyNameWithExtension = $assemblyName

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
            ForEach-Object { if ($_) { return $_ } }

        # this is rare (occasionally, some projects may have AssemblyName defined
        # using msbuild macro, e.g. <AssemblyName>$(RootNamespace)</AssemblyName>).
        # not happy, but try to adapt
        [string] $ns = $xml.Project.xmlns
        if ($producedAssembly -and $producedAssembly.StartsWith('$(') -and $producedAssembly.EndsWith(')')) {
            $macro = $producedAssembly.Substring(2, $producedAssembly.Length-3)
            if ($ns) {
                $producedAssembly = (Select-Xml -Xml $xml -XPath "/ns:Project//ns:$macro" -Namespace @{ns=$ns}).Node.InnerText
            }
            else {
                $producedAssembly = (Select-Xml -Xml $xml -XPath "/Project//$macro").Node.InnerText
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
            if ($ns) {
                $targetFrameworksInProjFile = (Select-Xml -Xml $xml -XPath "/ns:Project//ns:TargetFramework | /ns:Project//ns:TargetFrameworks" -Namespace @{ns=$ns}).Node.InnerText
            }
            else {
                $targetFrameworksInProjFile = (Select-Xml -Xml $xml -XPath "/Project//TargetFramework | /Project//TargetFrameworks").Node.InnerText
            }
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
    Write-Host -ForegroundColor Yellow "$assemblyNameWithExtension has no project file"
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
        $shortTfm = $tfm.Substring(0, 4)

        # a "standard" TFM can match any target framework
        if ($shortTfm -eq "nets") {
            return $true
        }
        elseif ($shortTfm -eq $targetFramework.Substring(0, 4)) {
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
                $line = [System.Environment]::ExpandEnvironmentVariables($line)
                $projects.Add($line)
            }
        }
        return $projects
    }

    # resume file does not exist
    return $null
}

<#
.SYNOPSIS
    Analyzes and returns the dependency list of the given project.
#>
function Get-DependencyList
{
    param (
        # the project file whose reference dependency list is retrieved
        [string]   $projectFile,
        # the base paths to folders where projects for reference dependencies are searched
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

        # if the project file was already added, move it to the bottom of the list.
        # to refect the fact that the project appears lower in the dependency tree.
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

<#
.SYNOPSIS
    Build dependency projects in the order they appear in the list.
#>
function Build-DependencyList
{
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param (
        # list of dependency projects to build
        [System.Collections.Generic.List[string]] $dependencyProjects,
        # arguments for build command
        [string] $buildArgs,
        # if present, run nuget restore before building each project
        [Parameter(Mandatory = $false)]
        [switch] $restore,
        # path to nuget tool (nuget.exe)
        [Parameter(Mandatory = $false)]
        [string] $nugetTool,
        # alternative command to get the project's external dependency binaries
        [Parameter(Mandatory = $false)]
        [string] $alterRestoreCommand,
        # file to store remaining dependency list for resuming build run in case
        # of build failure
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
            elseif ($alterRestoreCommand) {
                Write-Host "Running $alterRestoreCommand"
                & cmd.exe /c $alterRestoreCommand
            }
        }

        $args = $buildArgs.Trim().Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
        Write-Host "Running build.cmd with args: '$args'"
        & cmd.exe /c build.cmd $args

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

Write-Debug "ProjectFile: '$ProjectFile'"
Write-Debug "BasePath: '$BasePath'"
Write-Debug "Keyword: '$Keyword'"
Write-Debug "BuildArgs: '$BuildArgs'"
Write-Debug "DryRun: $DryRun"
Write-Debug "Resume: $Resume"
Write-Debug "Restore: $Restore"

if ($Restore.IsPresent) {
    $nuget = Get-NugetTool
    if (-not $nuget) {
        Write-Host -ForegroundColor Red "Restore option is specified but nuget tool is not available."
        Write-Host -ForegroundColor Red "Make sure env:NUGET_TOOL is set or nuget tool is accessible through env:PATH."
        exit
    }
}

# file containing dependency list for resuming run
$resumeFile = ".\build.deps.txt"

if ($Resume.IsPresent) {
    Write-Debug "Resuming dependency list from $resumeFile"
    $dependencyProjects = Get-ResumeList $resumeFile
    if (-not $dependencyProjects) {
        Write-Host -ForegroundColor Red "Resume file $resumeFile is required to resume build run."
        exit
    }
}
else {
    $startWatch = Get-Date

    Write-Debug "Getting dependency list for project: $ProjectFile"
    $dependencyProjects = Get-DependencyList $ProjectFile $BasePath $Keyword

    $endWatch = Get-Date
    $timeElapsed = ([TimeSpan]($endWatch-$startWatch)).TotalMinutes
    Write-Host "Total time to complete search: $timeElapsed minutes."
}

Write-Host -ForegroundColor Cyan "Building the following projects (total: $($dependencyProjects.Count)) in list order:"
$dependencyProjects

# exit the script if its a dry-run
if ($DryRun.IsPresent) {
    if (-not $Resume.IsPresent) {
        $dependencyProjects | Out-File $resumeFile
    }
    exit
}

if ($Restore.IsPresent) {
    $alterRestoreCommand = $env:ALTER_NUGET_TOOL
    Write-Debug "Buiding dependency list with: $BuildArgs -restore -nugetTool $nuget -alterRestoreCommand $alterRestoreCommand -resumeFile $resumeFile"
    Build-DependencyList $dependencyProjects $buildArgs -restore -nugetTool $nuget -alterRestoreCommand $alterRestoreCommand -resumeFile $resumeFile
}
else {
    Write-Debug "Buiding dependency list with: $BuildArgs -resumeFile $resumeFile"
    Build-DependencyList $dependencyProjects $BuildArgs -resumeFile $resumeFile
}
