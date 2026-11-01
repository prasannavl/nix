{
  z-push = {
    kind = "github-tags";
    owner = "Z-Hub";
    repo = "Z-Push";
    version = "2.7.6";
    hash = "sha256-cca6O8HfzzgZ3FdBRU7qWNsTlnzIE0l/YP71QuHYcJE=";
  };
  # AWL is a runtime PHP include-path dependency of z-push only, so its source
  # record lives with the consumer instead of as its own top-level package.
  awl = {
    kind = "gitlab-tags";
    project = "davical-project/awl";
    tagPrefix = "r";
    version = "0.65";
    hash = "sha256-dv61h6ZoJYBofWUfSWvJqg0IWOQJ/HgsgXNfNkLMHFk=";
  };
}
