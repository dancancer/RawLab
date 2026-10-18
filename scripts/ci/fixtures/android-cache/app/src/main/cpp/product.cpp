extern int dependency_answer();
extern "C" int answer() { return dependency_answer() + 2; }
