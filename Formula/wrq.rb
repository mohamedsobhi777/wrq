class Wrq < Formula
  desc "Local-first command-line library for research papers"
  homepage "https://github.com/mohamedsobhi777/wrq"
  url "https://github.com/mohamedsobhi777/wrq/archive/refs/tags/v0.1.2.tar.gz"
  sha256 "d37c06add0f92d4e5dd8e8334ebbc9104d6c2a12a368b737d959146046a29455"
  license "MIT"
  head "https://github.com/mohamedsobhi777/wrq.git", branch: "main"

  depends_on "ruby"
  on_linux do
    depends_on "xdg-utils"
  end

  def install
    libexec.install "wrq.rb", "lib"
    (bin/"wrq").write_env_script libexec/"wrq.rb",
      PATH: "#{formula_opt_bin("ruby")}:$PATH"
  end

  test do
    reported_version = shell_output("#{bin}/wrq --version").strip
    if build.head?
      assert_match(/^wrq \d+\.\d+\.\d+$/, reported_version)
    else
      assert_equal "wrq #{version}", reported_version
    end
    assert_match "research paper", shell_output("#{bin}/wrq --help")
  end
end
