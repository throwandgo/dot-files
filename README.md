# Setup
The below process is designed to be run on a brand new MacOS machine.

* Install Nix

  ```shell
  sh <(curl -L https://nixos.org/nix/install) --daemon
  ```

* Install the Xcode command line tools, which includes git

  ```shell
  xcode-select --install
  ```

* Clone this repo. Note that you may need to generate a new SSH key to clone via SSH.

  ```shell
  git clone git@github.com:throwandgo/dot-files.git ~/.config/home-manager
  ```

* Run the below script to sync the dependencies

  ```shell
  ./sync.sh
  ```
