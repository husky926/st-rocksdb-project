#include <iostream>
#include <memory>

#include <rocksdb/db.h>

int main() {
  rocksdb::Options options;
  options.create_if_missing = true;

  const std::string path = "rocksdb_data";

  std::unique_ptr<rocksdb::DB> db;
  auto status = rocksdb::DB::Open(options, path, &db);
  if (!status.ok()) {
    std::cerr << "DB::Open failed: " << status.ToString() << "\n";
    return 1;
  }

  status = db->Put(rocksdb::WriteOptions(), "k1", "hello");
  if (!status.ok()) {
    std::cerr << "Put failed: " << status.ToString() << "\n";
    return 1;
  }

  std::string value;
  status = db->Get(rocksdb::ReadOptions(), "k1", &value);
  if (!status.ok()) {
    std::cerr << "Get failed: " << status.ToString() << "\n";
    return 1;
  }

  std::cout << "k1=" << value << "\n";
  return 0;
}
