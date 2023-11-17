{ python3, ... }:

python3.buildPythonApplication {
  pname = "security-tracker";
  version = "dev";

  src = ../../../src/website;

  propagatedBuildInputs = with python3.pkgs; [
    django-allauth
    django_4
    pygithub
    requests
  ];
}
