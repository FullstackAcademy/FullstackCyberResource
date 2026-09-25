$feature = "OpenSSH.Server~~~~0.0.1.0"

for ($i = 10; $i -le 100; $i += 10) {
    Write-Progress `
        -Activity "Installing Windows Capability" `
        -Status "$feature - $i% Complete" `
        -PercentComplete $i

    Start-Sleep -Seconds 3
}

Write-Progress -Activity "Installing Windows Capability" -Completed

Write-Host ""
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host " TRUST, BUT VERIFY." -ForegroundColor Red
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "You just downloaded and executed a PowerShell script from a random forum post." -ForegroundColor White
Write-Host "You had no idea what that script actually did before you ran it." -ForegroundColor White
Write-Host ""
Write-Host "Good news: this script did NOT install OpenSSH." -ForegroundColor Green
Write-Host "It did not make any configuration changes to your system." -ForegroundColor Green
Write-Host ""
Write-Host "You already installed OpenSSH in the previous guide." -ForegroundColor Cyan
Write-Host "Why were you trying to install it again?" -ForegroundColor Cyan
Write-Host ""
Write-Host "This step was a red herring." -ForegroundColor Magenta
Write-Host "Read scripts before you run them. Trust, but verify." -ForegroundColor Yellow
Write-Host ""
