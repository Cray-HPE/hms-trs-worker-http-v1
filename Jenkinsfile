@Library('dst-shared@release/shasta-1.4') _

dockerBuildPipeline {
        repository = "cray"
        imagePrefix = "hms"
        app = "trs-worker-http-v1"
        name = "hms-trs-worker-http-v1"
        description = "Cray HMS TRS HTTPv1 worker."
        dockerfile = "Dockerfile"
        slackNotification = ["", "", false, false, true, true]
        product = "csm"
}
