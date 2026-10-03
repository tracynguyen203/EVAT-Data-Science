// =============================================================================
// EVAT Data Science - Jenkins CI/CD pipeline (WINDOWS agent)
// Stages: Build > Test > Code Quality > Security > Deploy > Release > Monitoring
//
// Credentials expected in Jenkins (Manage Jenkins > Credentials > Global):
//   sonarqube-token  (Secret text)
//   dockerhub-creds  (Username with password)
//   github-token     (Username with password - PAT)
//   uptime-kuma-push-token  (Secret text)  <- create this one for the Monitoring stage
// =============================================================================

// Polls a URL until the service answers with anything below HTTP 500.
def waitForHttp(String url) {
    withEnv(["CHECK_URL=${url}"]) {
        powershell '''
            $ok = $false
            for ($i = 1; $i -le 40; $i++) {
                try {
                    $r = Invoke-WebRequest -Uri $env:CHECK_URL -UseBasicParsing -TimeoutSec 5
                    Write-Host "UP - HTTP $($r.StatusCode)"
                    $ok = $true; break
                } catch {
                    if ($_.Exception.Response) {
                        $code = [int]$_.Exception.Response.StatusCode
                        if ($code -lt 500) { Write-Host "UP - HTTP $code"; $ok = $true; break }
                    }
                    Write-Host "Waiting for $($env:CHECK_URL) (attempt $i of 40)..."
                    Start-Sleep -Seconds 3
                }
            }
            if (-not $ok) { Write-Error "Service did not become healthy"; exit 1 }
        '''
    }
}

pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 60, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    environment {
        APP_NAME       = 'evat-data-science'
        IMAGE_TAG      = "${env.BUILD_NUMBER}"
        LOCAL_IMAGE    = "evat-data-science:${env.BUILD_NUMBER}"

        // ---- CHANGE THESE ----
        DH_NAMESPACE   = 'tracynguyen203'                                   // your Docker Hub username
        GITHUB_REPO    = 'github.com/tracynguyen203/EVAT-Data-Science.git' // repo you can push tags to
        // ----------------------

        PROD_IMAGE     = "tracynguyen203/evat-data-science:${env.BUILD_NUMBER}"
        SONAR_HOST_URL = 'http://host.docker.internal:9000'
        STAGING_PORT   = '5001'
        PROD_PORT      = '5000'
        KUMA_URL       = 'http://localhost:3001'   // Uptime Kuma dashboard
        DOCKER_BUILDKIT = '1'
    }

    stages {

        // ---------------------------------------------------------------- 1
        stage('Build') {
            steps {
                bat 'git log -1 --oneline'
                bat 'docker version'
                // Build artefact = versioned Docker image built from the root Dockerfile
                bat 'docker build -t %LOCAL_IMAGE% -t %APP_NAME%:latest .'
                bat '''
                    if not exist artifacts mkdir artifacts
                    docker image inspect %LOCAL_IMAGE% > artifacts\\image-inspect.json
                    docker images %APP_NAME% > artifacts\\images.txt
                '''
            }
        }

        // ---------------------------------------------------------------- 2
        stage('Test') {
            steps {
                bat 'if not exist reports mkdir reports'
                // Tests run INSIDE the freshly built image, so they validate the real artefact
                bat '''
                    docker run --rm -v "%WORKSPACE%/reports:/reports" %LOCAL_IMAGE% sh -c "pip install --no-cache-dir -q pytest && python -m pytest tests -v --junitxml=/reports/junit.xml"
                '''
            }
            post {
                always { junit allowEmptyResults: true, testResults: 'reports/junit.xml' }
            }
        }

        // ---------------------------------------------------------------- 3
        stage('Code Quality') {
            steps {
                withCredentials([string(credentialsId: 'sonarqube-token', variable: 'SONAR_TOKEN')]) {
                    // UNSTABLE (not FAILED) if the quality gate fails, so later stages still run
                    catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                        bat '''
                            docker run --rm -e SONAR_HOST_URL=%SONAR_HOST_URL% -e SONAR_TOKEN -v "%WORKSPACE%:/usr/src" sonarsource/sonar-scanner-cli -Dsonar.projectBaseDir=/usr/src -Dsonar.projectVersion=%IMAGE_TAG% -Dsonar.qualitygate.wait=true
                        '''
                    }
                }
            }
        }

        // ---------------------------------------------------------------- 4
        stage('Security') {
            steps {
                bat 'if not exist reports mkdir reports'

                // (a) Dependency vulnerabilities in requirements.txt
                catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                    bat '''
                        docker run --rm -v "%WORKSPACE%:/src" -w /src python:3.12.3-slim sh -c "pip install -q pip-audit && pip-audit -r main/requirements.txt --desc > reports/pip-audit.txt 2>&1; rc=$?; cat reports/pip-audit.txt; exit $rc"
                    '''
                }

                // (b) OS + library vulnerabilities in the built image (HIGH/CRITICAL with a fix available)
                //     Full report -> reports/trivy.txt (archived). Console only gets the totals, because the
                //     complete table can be thousands of lines long. Accepted findings go in .trivyignore.
                catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                    bat '''
                        docker run --rm -v //var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache/ -v "%WORKSPACE%:/src:ro" -v "%WORKSPACE%/reports:/reports" aquasec/trivy:latest image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --ignorefile /src/.trivyignore --no-progress --exit-code 1 --output /reports/trivy.txt %LOCAL_IMAGE%
                        set RC=%ERRORLEVEL%
                        if exist reports\\trivy.txt findstr /C:"Report Summary" /C:"Total:" /C:"(debian" /C:"python-pkg" reports\\trivy.txt
                        exit /b %RC%
                    '''
                }
            }
        }

        // ---------------------------------------------------------------- 5
        stage('Deploy') {
            steps {
                // Staging = same image, run via Docker Compose on port 5001
                withEnv(["APP_IMAGE=${env.LOCAL_IMAGE}", "HOST_PORT=${env.STAGING_PORT}"]) {
                    bat 'docker compose -p evat-staging down --remove-orphans'
                    bat 'docker compose -p evat-staging up -d'
                    script { waitForHttp("http://localhost:${env.STAGING_PORT}/") }
                    bat 'docker compose -p evat-staging ps'
                }
            }
            post {
                failure {
                    // Show WHY staging did not come up (container state + app logs)
                    withEnv(["APP_IMAGE=${env.LOCAL_IMAGE}", "HOST_PORT=${env.STAGING_PORT}"]) {
                        bat '''
                            docker compose -p evat-staging ps -a
                            docker compose -p evat-staging logs --tail 100 app
                            exit /b 0
                        '''
                    }
                }
            }
        }

        // ---------------------------------------------------------------- 6
        stage('Release') {
            steps {
                // (a) Publish the versioned image to Docker Hub
                withCredentials([usernamePassword(credentialsId: 'dockerhub-creds',
                                                  usernameVariable: 'DH_USER',
                                                  passwordVariable: 'DH_PASS')]) {
                    powershell '''
                        $remote = "$($env:DH_NAMESPACE)/$($env:APP_NAME)"
                        $env:DH_PASS | docker login -u $env:DH_USER --password-stdin
                        if ($LASTEXITCODE -ne 0) { exit 1 }
                        docker tag $env:LOCAL_IMAGE "${remote}:$($env:IMAGE_TAG)"
                        docker tag $env:LOCAL_IMAGE "${remote}:latest"
                        docker push "${remote}:$($env:IMAGE_TAG)"
                        if ($LASTEXITCODE -ne 0) { exit 1 }
                        docker push "${remote}:latest"
                        if ($LASTEXITCODE -ne 0) { exit 1 }
                        docker logout
                    '''
                }

                // (b) Tag the release in Git
                catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                    withCredentials([usernamePassword(credentialsId: 'github-token',
                                                      usernameVariable: 'GH_USER',
                                                      passwordVariable: 'GH_PAT')]) {
                        powershell '''
                            $tag = "v1.0.$($env:BUILD_NUMBER)"
                            git config user.email "jenkins@local"
                            git config user.name "Jenkins"
                            git tag -f $tag
                            git push "https://$($env:GH_USER):$($env:GH_PAT)@$($env:GITHUB_REPO)" $tag --force
                            if ($LASTEXITCODE -ne 0) { exit 1 }
                        '''
                    }
                }

                // (c) Promote to production: pull the image FROM Docker Hub and run it on port 5000
                withEnv(["APP_IMAGE=${env.PROD_IMAGE}", "HOST_PORT=${env.PROD_PORT}"]) {
                    bat 'docker compose -p evat-prod pull'
                    bat 'docker compose -p evat-prod up -d'
                    script { waitForHttp("http://localhost:${env.PROD_PORT}/") }
                }
            }
            post {
                failure {
                    withEnv(["APP_IMAGE=${env.PROD_IMAGE}", "HOST_PORT=${env.PROD_PORT}"]) {
                        bat '''
                            docker compose -p evat-prod ps -a
                            docker compose -p evat-prod logs --tail 100 app
                            exit /b 0
                        '''
                    }
                }
            }
        }

        // ---------------------------------------------------------------- 7
        stage('Monitoring') {
            steps {
                // Make sure Uptime Kuma is running next to the production app
                withEnv(["APP_IMAGE=${env.PROD_IMAGE}", "HOST_PORT=${env.PROD_PORT}"]) {
                    bat 'docker compose -p evat-prod --profile monitoring up -d'
                }
                script { waitForHttp("${env.KUMA_URL}/") }

                // Production health confirmation
                script { waitForHttp("http://localhost:${env.PROD_PORT}/") }

                // Send a "release OK" heartbeat to the Kuma push monitor
                withCredentials([string(credentialsId: 'uptime-kuma-push-token', variable: 'KUMA_TOKEN')]) {
                    powershell '''
                        $ErrorActionPreference = 'Stop'
                        $msg = [uri]::EscapeDataString("Build $($env:BUILD_NUMBER) released to production")
                        $url = "$($env:KUMA_URL)/api/push/$($env:KUMA_TOKEN)?status=up&msg=$msg&ping="
                        $r = Invoke-RestMethod -Uri $url -TimeoutSec 15
                        Write-Host "Uptime Kuma heartbeat sent: $($r | ConvertTo-Json -Compress)"
                    '''
                }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'reports/**,artifacts/**', allowEmptyArchive: true, fingerprint: true
        }
        success {
            echo "Pipeline OK - ${env.PROD_IMAGE} is running in production on port ${env.PROD_PORT}."
        }
        failure {
            // Automatic alert: a "down" heartbeat makes Uptime Kuma fire your notification (email/Discord/etc.)
            script {
                try {
                    withCredentials([string(credentialsId: 'uptime-kuma-push-token', variable: 'KUMA_TOKEN')]) {
                        powershell '''
                            $msg = [uri]::EscapeDataString("Pipeline FAILED - build $($env:BUILD_NUMBER)")
                            $url = "$($env:KUMA_URL)/api/push/$($env:KUMA_TOKEN)?status=down&msg=$msg&ping="
                            Invoke-RestMethod -Uri $url -TimeoutSec 15 | Out-Null
                        '''
                    }
                } catch (err) {
                    echo "Could not notify Uptime Kuma: ${err}"
                }
            }
        }
    }
}