{lib}: {
  metadata = {
    composeFiles,
    pullComposeFiles,
    composeArgs,
    expectedServices,
  }: {
    kind = "compose";
    compose = {
      files = composeFiles;
      pullFiles = pullComposeFiles;
      args = composeArgs;
      expectedServices = expectedServices;
    };
  };

  expectedContainers = serviceName: workingDir: expectedServices:
    map (composeService: {
      name = composeService;
      labels = {
        "com.docker.compose.project.working_dir" = workingDir;
        "com.docker.compose.service" = composeService;
      };
      owner = serviceName;
    })
    expectedServices;
}
