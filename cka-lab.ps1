#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Lab CKA : Hyper-V + Multipass + kubeadm + Calico, IP fixes, persistant au reboot.

.DESCRIPTION
  - vSwitch Hyper-V interne + WinNAT dédiés (IP stables, contrairement au Default Switch)
  - 1 control-plane + 2 workers Ubuntu, kubeadm, containerd, Calico (operator)
  - Démarrage auto des VM (Hyper-V) + tâche planifiée de réparation réseau au boot
  - Tout ce qui est propre au lab est dans -LabRoot (defaut D:\cka) : cloud-init, cle et config SSH,
    kubeconfig, logs
  - Le stockage Multipass (disques de TOUTES les VM Multipass, cache d'images) va dans -MultipassStorage
    (defaut D:\multipass), commun a tous tes labs Multipass ; deplace seulement si aucune instance n'existe
  - Hors de LabRoot (inevitable) : 1 bloc dans hosts Windows, 1 ligne Include dans ~/.ssh/config,
    vSwitch/NAT Hyper-V, tache planifiee, variable systeme MULTIPASS_STORAGE
  - Snapshot / Restore pour s'entraîner à casser/réparer le cluster

.EXAMPLE
  .\cka-lab.ps1 -Action Create
  .\cka-lab.ps1 -Action Status
  .\cka-lab.ps1 -Action Snapshot -SnapshotName avant-upgrade
  .\cka-lab.ps1 -Action Restore  -SnapshotName clean
  .\cka-lab.ps1 -Action Destroy
  .\cka-lab.ps1 -Action ResetStorage   # remet le stockage Multipass par defaut (C:\ProgramData\Multipass)
#>
[CmdletBinding()]
param(
    [ValidateSet('Create','Status','Snapshot','Restore','Repair','Destroy','ResetStorage')]
    [string]$Action        = 'Create',
    [string]$K8sMinor      = '1.34',        # examen = 1.35 -> 1.34 pour s'entrainer a l'upgrade
    [string]$CalicoVersion = 'v3.31.4',
    [string]$UbuntuImage   = '24.04',
    [string]$SwitchName    = 'CKA-Lab',
    [string]$NetPrefix     = '192.168.100', # /24 ; ne doit pas chevaucher ton LAN / VPN
    [string]$PodCidr       = '10.244.0.0/16',
    [string]$SnapshotName  = 'clean',
    [string]$LabRoot       = 'D:\cka',
    # Stockage Multipass = reglage GLOBAL (un seul par hote, partage par TOUTES les instances) :
    # volontairement hors de LabRoot pour pouvoir heberger d'autres labs Multipass.
    [string]$MultipassStorage = 'D:\multipass',
    [switch]$NoSnapshot
)

$ErrorActionPreference = 'Stop'
$Gateway = "$NetPrefix.1"
$LabCidr = "$NetPrefix.0/24"
$NatName = "$SwitchName-NAT"
$LabRoot    = [IO.Path]::GetFullPath($LabRoot).TrimEnd('\')
$CiDir      = Join-Path $LabRoot 'cloud-init'
$SshDir     = Join-Path $LabRoot 'ssh'
$SshKey     = Join-Path $SshDir  'cka_lab_ed25519'
$SshConfig  = Join-Path $SshDir  'config'
$KnownHosts = Join-Path $SshDir  'known_hosts'
$KubeDir    = Join-Path $LabRoot 'kube'
$KubeConfig = Join-Path $KubeDir 'config'
$LogDir     = Join-Path $LabRoot 'logs'
$MpStorage  = [IO.Path]::GetFullPath($MultipassStorage).TrimEnd('\')
$MpRegPath  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$TaskName = 'CKA-Lab-Repair'

# Dimensionnement : kubeadm exige >= 2 vCPU / 2 Go pour le control-plane
$Nodes = @(
    @{ Name='cka-cp1'; Ip="$NetPrefix.10"; Cpu=2; Mem='4G'; Disk='30G'; Role='cp' }
    @{ Name='cka-w1';  Ip="$NetPrefix.11"; Cpu=2; Mem='3G'; Disk='25G'; Role='worker' }
    @{ Name='cka-w2';  Ip="$NetPrefix.12"; Cpu=2; Mem='3G'; Disk='25G'; Role='worker' }
)
$NodeNames = $Nodes | ForEach-Object { $_.Name }
$Cp        = $Nodes | Where-Object { $_.Role -eq 'cp' } | Select-Object -First 1
$Workers   = $Nodes | Where-Object { $_.Role -eq 'worker' }

# ---------------------------------------------------------------- templates
$CloudInitTemplate = @'
#cloud-config
package_update: true
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gpg
  - containerd
  - jq
  - bash-completion
  - vim
ssh_authorized_keys:
  - __PUBKEY__
write_files:
  - path: /etc/netplan/60-cka-lab.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          lab0:
            match:
              macaddress: "__MAC__"
            dhcp4: false
            addresses: [__IP__/24]
            routes:
              - to: default
                via: __GW__
                metric: 50
            nameservers:
              addresses: [1.1.1.1, 9.9.9.9]
  - path: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter
  - path: /etc/sysctl.d/99-k8s.conf
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward                 = 1
  - path: /etc/crictl.yaml
    content: |
      runtime-endpoint: unix:///run/containerd/containerd.sock
      image-endpoint: unix:///run/containerd/containerd.sock
  - path: /etc/hosts
    append: true
    content: |
__HOSTS__
__CP_FILES__
runcmd:
  - modprobe overlay
  - modprobe br_netfilter
  - sysctl --system
  - netplan apply
  - swapoff -a
  - mkdir -p /etc/containerd
  - containerd config default > /etc/containerd/config.toml
  - sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  - systemctl restart containerd
  - mkdir -p -m 755 /etc/apt/keyrings
  - curl -fsSL https://pkgs.k8s.io/core:/stable:/v__K8S__/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  - echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v__K8S__/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
  - apt-get update
  - DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet kubeadm kubectl
  - apt-mark hold kubelet kubeadm kubectl
  - echo 'KUBELET_EXTRA_ARGS=--node-ip=__IP__' > /etc/default/kubelet
  - systemctl enable --now kubelet
  - DEBIAN_FRONTEND=noninteractive apt-get install -y etcd-client || true
  - echo 'source <(kubectl completion bash); alias k=kubectl; complete -o default -F __start_kubectl k' >> /home/ubuntu/.bashrc
'@

# Fichiers supplementaires pour le control-plane (inseres dans write_files)
$CpFilesTemplate = @'
  - path: /usr/local/sbin/cka-init-cp.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      if [ -f /etc/kubernetes/admin.conf ]; then echo "control-plane deja initialise"; exit 0; fi
      kubeadm init \
        --apiserver-advertise-address=__IP__ \
        --control-plane-endpoint=__IP__:6443 \
        --pod-network-cidr=__PODCIDR__ \
        --node-name="$(hostname)"
      mkdir -p /home/ubuntu/.kube
      cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
      chown -R ubuntu:ubuntu /home/ubuntu/.kube
      export KUBECONFIG=/etc/kubernetes/admin.conf
      kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/__CALICO__/manifests/operator-crds.yaml
      kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/__CALICO__/manifests/tigera-operator.yaml
      kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=180s
      kubectl create -f /root/calico-installation.yaml
      snap install helm --classic || true
  - path: /root/calico-installation.yaml
    content: |
      apiVersion: operator.tigera.io/v1
      kind: Installation
      metadata:
        name: default
      spec:
        calicoNetwork:
          ipPools:
            - name: default-ipv4-ippool
              blockSize: 26
              cidr: __PODCIDR__
              encapsulation: VXLAN
              natOutgoing: Enabled
              nodeSelector: all()
          nodeAddressAutodetectionV4:
            cidrs:
              - "__LABCIDR__"
      ---
      apiVersion: operator.tigera.io/v1
      kind: APIServer
      metadata:
        name: default
      spec: {}
'@

# ---------------------------------------------------------------- helpers
# PowerShell 5.1 + ErrorActionPreference=Stop transforme tout texte ecrit sur stderr par un exe
# (ex. le warning absl de multipass) en erreur fatale. On isole donc les appels natifs.
function Invoke-Mp {
    $ErrorActionPreference = 'Continue'
    & multipass @args
    if ($LASTEXITCODE -ne 0) { throw "multipass $($args -join ' ') a echoue (code $LASTEXITCODE)" }
}

# Execute multipass, ignore stderr, renvoie @{ Code; Out } (Out = stdout brut en lignes)
function Get-MpOutput {
    $ErrorActionPreference = 'Continue'
    $lines = & multipass @args 2>&1 | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
             ForEach-Object { "$_" }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = @($lines) }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
}

function Get-NodeMac([string]$Ip) {
    '52:54:00:c4:a0:{0:x2}' -f [int]($Ip.Split('.')[-1])
}

function Get-MpInstances {
    $raw = (Get-MpOutput list --format json).Out -join "`n"
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    @(($raw | ConvertFrom-Json).list | ForEach-Object { $_.name })
}

function Set-MarkedBlock([string]$Path, [string]$Block, [switch]$Remove, [switch]$Prepend) {
    $begin = '# >>> CKA-LAB'; $end = '# <<< CKA-LAB'
    $content = ''
    if (Test-Path $Path) { $content = [IO.File]::ReadAllText($Path) }
    $pattern = "(?s)$([regex]::Escape($begin)).*?$([regex]::Escape($end))\r?\n?"
    $content = [regex]::Replace($content, $pattern, '').Trim()
    if (-not $Remove) {
        $blk = "$begin`r`n$Block`r`n$end"
        $content = if ($Prepend) { "$blk`r`n`r`n$content" } else { "$content`r`n`r`n$blk" }
    }
    [IO.File]::WriteAllText($Path, $content.Trim() + "`r`n", (New-Object Text.UTF8Encoding($false)))
}

# OpenSSH Windows refuse une cle privee lisible par d'autres comptes : sur D:\ les droits herites
# (Utilisateurs authentifies...) la rendraient inutilisable. On restreint a : toi, SYSTEM, Administrateurs.
function Set-PrivateAcl([string]$Path) {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $Path /inheritance:r /grant:r "${me}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls a echoue sur $Path" }
    Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        & icacls $_.FullName /reset | Out-Null
        & icacls $_.FullName /setowner $me | Out-Null
    }
}

function Wait-MpDaemon {
    for ($i = 0; $i -lt 30; $i++) {
        $r = Get-MpOutput get local.driver
        $d = ($r.Out -join '').Trim()
        if ($r.Code -eq 0 -and $d) { return $d }
        Start-Sleep 2
    }
    throw "Le daemon Multipass ne repond pas apres 60 s. Essaie : Restart-Service Multipass ; sinon reinstalle Multipass."
}

# ---------------------------------------------------------------- etapes
function Assert-Prereqs {
    if (-not (Get-Command New-VMSwitch -ErrorAction SilentlyContinue)) {
        throw "Hyper-V absent. Active-le : Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All (Windows Pro/Entreprise requis), puis reboot."
    }
    if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) {
        throw "Multipass absent : winget install Canonical.Multipass, puis rouvre un PowerShell admin."
    }
    # Le client multipass a besoin du service multipassd : on le demarre, on le passe en auto, on attend le socket
    $svc = Get-Service -Name 'Multipass*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $svc) { throw "Service Multipass introuvable : reinstalle Multipass (winget install Canonical.Multipass)." }
    if ($svc.StartType -ne 'Automatic') { Set-Service -Name $svc.Name -StartupType Automatic }
    if ($svc.Status -ne 'Running') {
        Write-Host "[mp] Demarrage du service $($svc.Name)"
        Start-Service -Name $svc.Name
    }
    $drv = Wait-MpDaemon
    if ($drv -ne 'hyperv') { throw "Driver Multipass = '$drv'. Fais : multipass set local.driver=hyperv" }
    if (-not (Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue)) {
        Write-Warning "Default Switch introuvable : Multipass en a besoin pour son interface de gestion."
    }
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        throw "Client OpenSSH absent : Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
    }
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    if ($ramGB -lt 16) { Write-Warning "Hote a $ramGB Go de RAM : le lab en consomme ~10 Go. Reduis Mem dans `$Nodes si besoin." }
    $drive = Split-Path $LabRoot -Qualifier
    if (-not (Test-Path "$drive\")) { throw "Le lecteur $drive n'existe pas." }
    $freeGB = [math]::Round((Get-PSDrive $drive.TrimEnd(':')).Free / 1GB)
    if ($freeGB -lt 90) { Write-Warning "$drive : $freeGB Go libres. Les disques des VM peuvent grossir jusqu'a ~80 Go." }
}

function Ensure-LabDirs {
    foreach ($d in $LabRoot, $CiDir, $SshDir, $KubeDir, $LogDir) { New-Item -ItemType Directory -Force $d | Out-Null }
    Set-PrivateAcl $SshDir
    Set-PrivateAcl $KubeDir   # le kubeconfig contient un certificat cluster-admin
}

# ---- Stockage Multipass (disques des VM + cache d'images) dans LabRoot --------------------------
# Choix retenus :
#  - Reglage global a Multipass => applique uniquement quand AUCUNE instance n'existe (rien a migrer,
#    rien a casser). Sinon : avertissement, le lab se cree sur le stockage actuel.
#  - Variable posee a 2 endroits : environnement systeme (procedure officielle Multipass) ET
#    environnement propre au service (cle Services\<svc>\Environment, relue par le SCM a chaque
#    demarrage du service) => pas besoin de redemarrer Windows.
#  - Verification factuelle apres chaque launch : le VHDX doit etre sous LabRoot, sinon arret net.
#  - Reversible : -Action ResetStorage.

function Get-MpStorageSetting {
    (Get-ItemProperty -Path $MpRegPath -Name MULTIPASS_STORAGE -ErrorAction SilentlyContinue).MULTIPASS_STORAGE
}

function Test-MpStorageIsLab {
    $cur = Get-MpStorageSetting
    [bool]($cur -and ($cur.TrimEnd('\') -ieq $MpStorage))
}

function Get-MpServiceName {
    (Get-Service -Name 'Multipass*' | Select-Object -First 1).Name
}

# Ajoute/retire MULTIPASS_STORAGE dans l'environnement du service. Renvoie $true si modifie.
function Set-MpServiceEnv([string]$SvcName, [string]$Value) {
    $key  = "HKLM:\SYSTEM\CurrentControlSet\Services\$SvcName"
    $cur  = @((Get-ItemProperty -Path $key -Name Environment -ErrorAction SilentlyContinue).Environment | Where-Object { $_ })
    $keep = @($cur | Where-Object { $_ -notlike 'MULTIPASS_STORAGE=*' })
    $new  = if ($Value) { $keep + "MULTIPASS_STORAGE=$Value" } else { $keep }
    if ((@($cur) -join '|') -eq (@($new) -join '|')) { return $false }
    if ($new.Count -gt 0) {
        New-ItemProperty -Path $key -Name Environment -PropertyType MultiString -Value ([string[]]$new) -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $key -Name Environment -ErrorAction SilentlyContinue
    }
    return $true
}

function Ensure-MpStorage {
    $svc = Get-MpServiceName
    if (Test-MpStorageIsLab) {
        if (Set-MpServiceEnv $svc $MpStorage) {
            Write-Host "[mp] MULTIPASS_STORAGE ajoute a l'environnement du service, redemarrage du service"
            Restart-Service -Name $svc
            $null = Wait-MpDaemon
        }
        Write-Host "[mp] Stockage Multipass : $MpStorage"
        return
    }
    $current = Get-MpStorageSetting
    $source  = if ($current) { $current } else { Join-Path $env:ProgramData 'Multipass' }
    $instances = @(Get-MpInstances)
    if ($instances.Count -gt 0) {
        Write-Warning ("Stockage Multipass NON deplace (reste dans '$source') : instance(s) existante(s) : $($instances -join ', ').`n" +
                       "Les disques des VM du lab seront dans '$source'. Pour les avoir dans $MpStorage : supprime ces instances puis relance.")
        return
    }
    Write-Host "[mp] Deplacement du stockage Multipass : $source -> $MpStorage"
    Stop-Service -Name $svc
    New-Item -ItemType Directory -Force $MpStorage | Out-Null
    & icacls $MpStorage /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls a echoue sur $MpStorage" }
    if (Test-Path $source) {
        # Copie integrale (certificats client/daemon, reglages, cache d'images) comme le demande la doc Multipass
        & robocopy $source $MpStorage /E /COPY:DATS /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { Start-Service -Name $svc; throw "robocopy $source -> $MpStorage a echoue (code $LASTEXITCODE). Rien n'a ete modifie dans la config Multipass." }
    }
    Set-ItemProperty -Path $MpRegPath -Name MULTIPASS_STORAGE -Value $MpStorage
    $null = Set-MpServiceEnv $svc $MpStorage
    Start-Service -Name $svc
    $drv = Wait-MpDaemon
    if ($drv -ne 'hyperv') { Invoke-Mp set local.driver=hyperv; $null = Wait-MpDaemon }
    Write-Host "[mp] Stockage deplace. L'ancien dossier '$source' n'est plus utilise (a supprimer quand tu veux)."
}

# Verification factuelle : le disque de la VM doit etre sous LabRoot si c'est ce qui est configure.
function Assert-VmOnLabRoot([string]$Name) {
    if (-not (Test-MpStorageIsLab)) { return }
    $paths = @(Get-VMHardDiskDrive -VMName $Name -ErrorAction SilentlyContinue | ForEach-Object { $_.Path -replace '/', '\' })
    if ($paths.Count -eq 0) { Write-Warning "Impossible de lire les disques Hyper-V de $Name : verification sautee."; return }
    $bad = @($paths | Where-Object { $_ -notlike "$MpStorage\*" })
    if ($bad.Count) {
        throw ("Le disque de $Name est dans '$($bad -join ', ')' et non sous $MpStorage : le service Multipass n'utilise pas MULTIPASS_STORAGE.`n" +
               "Redemarre Windows, puis : .\cka-lab.ps1 -Action Destroy ; .\cka-lab.ps1 -Action Create")
    }
    Write-Host "[mp] Disque de $Name bien sous $MpStorage"
}

# Retour au stockage par defaut de Multipass (C:\ProgramData\Multipass). Exige zero instance.
function Reset-MpStorage {
    $instances = @(Get-MpInstances)
    if ($instances.Count -gt 0) { throw "Instances Multipass existantes, CKA ou non ($($instances -join ', ')) : le stockage est commun a toutes, supprime-les d'abord." }
    $svc = Get-MpServiceName
    $default = Join-Path $env:ProgramData 'Multipass'
    Stop-Service -Name $svc
    if ((Test-Path $MpStorage) -and -not (Test-Path (Join-Path $default 'data'))) {
        & robocopy $MpStorage $default /E /COPY:DATS /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { Start-Service -Name $svc; throw "robocopy $MpStorage -> $default a echoue (code $LASTEXITCODE)" }
    }
    Remove-ItemProperty -Path $MpRegPath -Name MULTIPASS_STORAGE -ErrorAction SilentlyContinue
    $null = Set-MpServiceEnv $svc $null
    Start-Service -Name $svc
    $null = Wait-MpDaemon
    Write-Host "Multipass (toutes instances confondues) utilise de nouveau $default. $MpStorage peut etre supprime."
}

function Ensure-Network {
    $createdSwitch = $false
    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        Write-Host "[net] Creation du vSwitch interne '$SwitchName'"
        New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
        $createdSwitch = $true
        Start-Sleep 3
    }
    try {
        $ifIndex = (Get-NetAdapter -Name "vEthernet ($SwitchName)").ifIndex
        if (-not (Get-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $Gateway -ErrorAction SilentlyContinue)) {
            $clash = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                     Where-Object { $_.IPAddress -like "$NetPrefix.*" -and $_.InterfaceIndex -ne $ifIndex }
            if ($clash) { throw "Le reseau $LabCidr est deja utilise par '$($clash[0].InterfaceAlias)'. Relance avec un autre -NetPrefix." }
            Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "[net] IP hote $Gateway/24 sur vEthernet ($SwitchName)"
            New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $Gateway -PrefixLength 24 | Out-Null
        }

        $allNat = @(Get-NetNat -ErrorAction SilentlyContinue)
        $same   = $allNat | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $LabCidr } | Select-Object -First 1
        if ($same) {
            if ($same.Name -eq $NatName) { return }
            throw @"
Le NAT '$($same.Name)' (hors lab CKA) couvre deja $LabCidr.
Le reutiliser lierait le lab a un autre environnement (IP en conflit, perte d'Internet s'il est supprime).
  - S'il ne sert plus : Remove-NetNat -Name '$($same.Name)' -Confirm:`$false  puis relance.
  - S'il sert encore  : relance avec un autre prefixe, ex. -NetPrefix 192.168.150
"@
        }
        if ($allNat.Count -gt 0) {
            Write-Warning "NAT existant(s) : $(($allNat | ForEach-Object { "$($_.Name)=$($_.InternalIPInterfaceAddressPrefix)" }) -join ', ')"
        }
        Write-Host "[net] Creation du NAT '$NatName' ($LabCidr)"
        try {
            New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $LabCidr | Out-Null
        } catch {
            $hns = ''
            if (Get-Command hnsdiag.exe -ErrorAction SilentlyContinue) { $ErrorActionPreference = 'Continue'; $hns = (& hnsdiag.exe list networks 2>&1 | ForEach-Object { "$_" } | Out-String).Trim() }
            throw @"
New-NetNat refuse $LabCidr : $($_.Exception.Message)
Cause probable : un autre NAT reclame deja ce prefixe ou le NAT unique de l'hote. Il peut etre invisible dans Get-NetNat
(reseau HNS/ICS cree par Docker Desktop, WSL, Windows Sandbox, conteneurs Windows, etc.).
Reseaux HNS detectes :
$hns
Solutions :
  1. Redemarrer Windows puis relancer (supprime souvent un NAT 'fantome').
  2. Relancer sur un autre prefixe : .\cka-lab.ps1 -NetPrefix 192.168.150
Le vSwitch cree par cette execution a ete retire, rien d'autre n'a ete modifie.
"@
        }
    } catch {
        if ($createdSwitch) {
            Remove-VMSwitch -Name $SwitchName -Force -ErrorAction SilentlyContinue
            Write-Host "[net] Rollback : vSwitch '$SwitchName' supprime"
        }
        throw
    }
}

function Ensure-SshKey {
    if (-not (Test-Path $SshKey)) {
        Write-Host "[ssh] Generation de la cle $SshKey"
        cmd /c "ssh-keygen -q -t ed25519 -N `"`" -C cka-lab -f `"$SshKey`""
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen a echoue" }
    }
    Set-PrivateAcl $SshDir
}

function New-CloudInit($n, [string]$pub) {
    $hosts = ($Nodes | ForEach-Object { "      $($_.Ip) $($_.Name)" }) -join "`n"
    $cpFiles = if ($n.Role -eq 'cp') { $CpFilesTemplate } else { '' }
    $CloudInitTemplate.Replace('__CP_FILES__', $cpFiles).
        Replace('__HOSTS__',   $hosts).
        Replace('__PUBKEY__',  $pub).
        Replace('__MAC__',     (Get-NodeMac $n.Ip)).
        Replace('__IP__',      $n.Ip).
        Replace('__GW__',      $Gateway).
        Replace('__K8S__',     $K8sMinor).
        Replace('__CALICO__',  $CalicoVersion).
        Replace('__PODCIDR__', $PodCidr).
        Replace('__LABCIDR__', $LabCidr)
}

function New-Nodes {
    $pub = (Get-Content "$SshKey.pub" -Raw).Trim()
    $existing = Get-MpInstances
    foreach ($n in $Nodes) {
        if ($existing -contains $n.Name) { Write-Host "[vm] $($n.Name) existe deja, ignore"; continue }
        $ci = Join-Path $CiDir "$($n.Name).yaml"
        Write-Utf8NoBom $ci (New-CloudInit $n $pub)
        Write-Host "[vm] Lancement $($n.Name) -> $($n.Ip) ($($n.Cpu) vCPU / $($n.Mem) / $($n.Disk))"
        Invoke-Mp launch $UbuntuImage --name $n.Name --cpus $n.Cpu --memory $n.Mem --disk $n.Disk `
            --network "name=$SwitchName,mode=manual,mac=$(Get-NodeMac $n.Ip)" `
            --cloud-init $ci --timeout 1800
        Assert-VmOnLabRoot $n.Name
    }
    foreach ($name in $NodeNames) {
        Write-Host "[vm] Attente cloud-init sur $name"
        $r = Get-MpOutput exec $name '--' cloud-init status --wait
        if ($r.Code -notin 0, 2) { throw "cloud-init en erreur sur $name : multipass exec $name -- sudo cat /var/log/cloud-init-output.log" }
    }
}

function Set-AutoStart {
    Write-Host "[hyperv] Demarrage automatique des VM au boot de l'hote"
    Invoke-Mp stop @($NodeNames)
    $i = 0
    foreach ($name in $NodeNames) {
        Set-VM -Name $name -AutomaticStartAction Start -AutomaticStartDelay (10 + 20 * $i) -AutomaticStopAction ShutDown
        $i++
    }
    Invoke-Mp start @($NodeNames)
}

function Register-RepairTask {
    $dst = Join-Path $LabRoot 'cka-lab.ps1'
    if ($PSCommandPath -ine $dst) { Copy-Item $PSCommandPath $dst -Force }
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$dst`" -Action Repair -SwitchName $SwitchName -NetPrefix $NetPrefix -LabRoot `"$LabRoot`""
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trg = New-ScheduledTaskTrigger -AtStartup
    $pr  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Principal $pr -Force | Out-Null
    Write-Host "[task] Tache planifiee '$TaskName' enregistree (verif vSwitch/NAT + demarrage VM au boot)"
}

function Initialize-Cluster {
    Write-Host "[k8s] kubeadm init + Calico sur $($Cp.Name)"
    Invoke-Mp exec $Cp.Name '--' sudo /usr/local/sbin/cka-init-cp.sh
    $join = ((Get-MpOutput exec $Cp.Name '--' sudo kubeadm token create --print-join-command).Out -join ' ').Trim()
    if (-not $join.StartsWith('kubeadm join')) { throw "Commande de join invalide : $join" }
    foreach ($w in $Workers) {
        if ((Get-MpOutput exec $w.Name '--' test -f /etc/kubernetes/kubelet.conf).Code -eq 0) { Write-Host "[k8s] $($w.Name) deja joint"; continue }
        Write-Host "[k8s] Join $($w.Name)"
        $joinArgs = $join -split '\s+'
        Invoke-Mp exec $w.Name '--' sudo @joinArgs
    }
    Write-Host "[k8s] Attente des noeuds Ready (pull des images Calico, quelques minutes)"
    Invoke-Mp exec $Cp.Name '--' kubectl wait --for=condition=Ready nodes --all --timeout=900s
}

function Set-HostAccess {
    Write-Host "[host] Mise a jour du fichier hosts Windows"
    $hostsBlock = ($Nodes | ForEach-Object { "$($_.Ip) $($_.Name)" }) -join "`r`n"
    Set-MarkedBlock "$env:SystemRoot\System32\drivers\etc\hosts" $hostsBlock

    Write-Host "[host] Config SSH du lab : $SshConfig"
    $keyPath = $SshKey -replace '\\', '/'
    $khPath  = $KnownHosts -replace '\\', '/'
    $sshText = ($Nodes | ForEach-Object {
        "Host $($_.Name)`r`n  HostName $($_.Ip)`r`n  User ubuntu`r`n  IdentityFile `"$keyPath`"`r`n  IdentitiesOnly yes`r`n  StrictHostKeyChecking accept-new`r`n  UserKnownHostsFile `"$khPath`""
    }) -join "`r`n`r`n"
    [IO.File]::WriteAllText($SshConfig, $sshText + "`r`n", (New-Object Text.UTF8Encoding($false)))

    # Seule trace dans ~/.ssh/config : un Include place EN TETE (apres un bloc Host, il ne s'appliquerait qu'a ce Host)
    Write-Host "[host] Include de $SshConfig en tete de ~/.ssh/config"
    $userSsh = Join-Path $HOME '.ssh'
    New-Item -ItemType Directory -Force $userSsh | Out-Null
    $incPath = $SshConfig -replace '\\', '/'
    if ($incPath -match '\s') { $incPath = "`"$incPath`"" }
    Set-MarkedBlock (Join-Path $userSsh 'config') "Include $incPath" -Prepend

    Write-Host "[host] Copie du kubeconfig vers $KubeConfig"
    # 'multipass exec ... cat' peut rester bloque sous Windows sur une sortie volumineuse : on transfere le fichier.
    # Chemin relatif volontaire : un chemin 'D:\...' risque d'etre lu comme 'instance:chemin'.
    Push-Location $KubeDir
    try {
        Remove-Item 'config' -ErrorAction SilentlyContinue
        Invoke-Mp transfer "$($Cp.Name):/home/ubuntu/.kube/config" 'config'
    } finally { Pop-Location }
    Set-PrivateAcl $KubeDir
    Set-PrivateAcl $SshDir

    # Workspace VS Code : ouvrir LabRoot dans VS Code => terminal integre avec le KUBECONFIG du lab
    $vsDir = Join-Path $LabRoot '.vscode'
    $vsSettings = Join-Path $vsDir 'settings.json'
    if (-not (Test-Path $vsSettings)) {
        New-Item -ItemType Directory -Force $vsDir | Out-Null
        $json = @{ 'terminal.integrated.env.windows' = @{ KUBECONFIG = $KubeConfig } } | ConvertTo-Json -Depth 3
        [IO.File]::WriteAllText($vsSettings, $json, (New-Object Text.UTF8Encoding($false)))
        Write-Host "[vscode] $vsSettings cree (KUBECONFIG du lab dans le terminal integre)"
    }
    # Pas d'appel a 'code' ici : lance depuis une session admin, le CLI VS Code peut rester bloque.
    Write-Host "[vscode] A faire une fois, dans un terminal NON admin : code --install-extension ms-vscode-remote.remote-ssh"
}

function Save-LabSnapshot {
    Write-Host "[snap] Arret du lab et snapshot '$SnapshotName'"
    Invoke-Mp stop @($NodeNames)
    foreach ($name in $NodeNames) { Invoke-Mp snapshot $name --name $SnapshotName }
    Invoke-Mp start @($NodeNames)
}

function Restore-LabSnapshot {
    Write-Host "[snap] Restauration '$SnapshotName'"
    Invoke-Mp stop @($NodeNames)
    foreach ($name in $NodeNames) { Invoke-Mp restore "$name.$SnapshotName" --destructive }
    Invoke-Mp start @($NodeNames)
}

function Show-Status {
    (Get-MpOutput list).Out
    Get-NetNat -Name $NatName -ErrorAction SilentlyContinue | Format-Table Name, InternalIPInterfaceAddressPrefix
    (Get-MpOutput exec $Cp.Name '--' kubectl get nodes -o wide).Out
}

function Invoke-Repair {
    New-Item -ItemType Directory -Force $LogDir | Out-Null
    Start-Transcript -Path (Join-Path $LogDir 'repair.log') -Append | Out-Null
    try {
        Ensure-Network
        foreach ($name in $NodeNames) {
            $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
            if ($vm -and $vm.State -eq 'Off') { Start-VM -Name $name; Start-Sleep 20 }
        }
    } finally { Stop-Transcript | Out-Null }
}

function Remove-Lab {
    if ((Read-Host "Supprimer DEFINITIVEMENT le lab (VM, vSwitch, NAT) ? Tape OUI") -ne 'OUI') { return }
    $existing = Get-MpInstances
    $toDelete = @($NodeNames | Where-Object { $existing -contains $_ })
    if ($toDelete.Count) { Invoke-Mp delete --purge @toDelete }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetNat -Name $NatName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-VMSwitch -Name $SwitchName -Force -ErrorAction SilentlyContinue
    Set-MarkedBlock "$env:SystemRoot\System32\drivers\etc\hosts" '' -Remove
    Set-MarkedBlock (Join-Path $HOME '.ssh\config') '' -Remove
    Remove-Item $CiDir, $KubeDir, $LogDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $SshConfig, $KnownHosts -Force -ErrorAction SilentlyContinue
    Write-Host "Lab supprime."
    Write-Host "Conserves dans $LabRoot : le script, la cle SSH, .vscode, et le stockage Multipass ($MpStorage, cache d'images)."
    Write-Host "Multipass reste configure sur $MpStorage. Pour revenir au defaut : .\cka-lab.ps1 -Action ResetStorage"
}

function New-Lab {
    Assert-Prereqs
    Ensure-LabDirs
    Ensure-MpStorage
    Ensure-Network
    Ensure-SshKey
    New-Nodes
    Set-AutoStart
    Register-RepairTask
    Initialize-Cluster
    Set-HostAccess
    if (-not $NoSnapshot) { Save-LabSnapshot }
    Write-Host ""
    Write-Host "=== Lab CKA pret ===" -ForegroundColor Green
    $Nodes | ForEach-Object { Write-Host ("  {0,-8} {1}" -f $_.Name, $_.Ip) }
    Write-Host "  VS Code  : F1 > Remote-SSH: Connect to Host > $($Cp.Name)"
    Write-Host "  VS Code  : ouvre le dossier $LabRoot => terminal integre deja pointe sur le kubeconfig du lab"
    Write-Host "  kubectl  : `$env:KUBECONFIG=`"$KubeConfig`""
    if (-not $NoSnapshot) { Write-Host "  Reset    : .\cka-lab.ps1 -Action Restore -SnapshotName $SnapshotName" }
}

switch ($Action) {
    'Create'   { New-Lab }
    'Status'   { Show-Status }
    'Snapshot' { Save-LabSnapshot }
    'Restore'  { Restore-LabSnapshot }
    'Repair'   { Invoke-Repair }
    'Destroy'  { Remove-Lab }
    'ResetStorage' { Reset-MpStorage }
}
