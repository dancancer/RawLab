int dependency();
extern "C" int answer() { return dependency() + 1; }
