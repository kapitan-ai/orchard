import Darwin
import Foundation

let path = CommandLine.arguments[1]
let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)

guard descriptor >= 0 else {
  exit(74)
}

guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
  close(descriptor)
  exit(errno == EWOULDBLOCK ? 75 : 74)
}

print("READY")
fflush(stdout)
_ = readLine()
flock(descriptor, LOCK_UN)
close(descriptor)
