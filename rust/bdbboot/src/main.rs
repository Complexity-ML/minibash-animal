use std::fs;

#[derive(Debug)]
#[allow(dead_code)]
struct Service {
    name: String,
    command: String,
    autostart: String,
    restart: String,
    desired: String,
    status: String,
    pid: String,
    description: String,
}

fn main() {
    println!("[bdbboot:rust] Linux+Bash+bdb hybrid boot helper");

    let path = "/var/bdb/tables/services/data.tsv";
    let data = match fs::read_to_string(path) {
        Ok(data) => data,
        Err(err) => {
            println!("[bdbboot:rust] cannot read {path}: {err}");
            return;
        }
    };

    let services: Vec<Service> = data
        .lines()
        .filter_map(parse_service)
        .collect();

    println!("[bdbboot:rust] {} services loaded from bdb", services.len());
    for service in services {
        if service.desired == "up" {
            println!(
                "[bdbboot:rust] want-up {} -> {} (restart={}, {})",
                service.name, service.command, service.restart, service.description
            );
        } else {
            println!(
                "[bdbboot:rust] want-down {} status={} pid={}",
                service.name, service.status, service.pid
            );
        }
    }
}

fn parse_service(line: &str) -> Option<Service> {
    let fields: Vec<String> = line
        .split('\t')
        .map(decode_b64)
        .collect::<Result<Vec<_>, _>>()
        .ok()?;

    if fields.len() < 8 {
        return None;
    }

    Some(Service {
        name: fields[0].clone(),
        command: fields[1].clone(),
        autostart: fields[2].clone(),
        restart: fields[3].clone(),
        desired: fields[4].clone(),
        status: fields[5].clone(),
        pid: fields[6].clone(),
        description: fields[7].clone(),
    })
}

fn decode_b64(input: &str) -> Result<String, String> {
    let mut out = Vec::new();
    let mut quartet = [0u8; 4];
    let mut q_len = 0;

    for byte in input.bytes() {
        quartet[q_len] = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => 64,
            b'\n' | b'\r' | b' ' => continue,
            _ => return Err(format!("invalid base64 byte: {byte}")),
        };
        q_len += 1;

        if q_len == 4 {
            out.push((quartet[0] << 2) | (quartet[1] >> 4));
            if quartet[2] != 64 {
                out.push((quartet[1] << 4) | (quartet[2] >> 2));
            }
            if quartet[3] != 64 {
                out.push((quartet[2] << 6) | quartet[3]);
            }
            q_len = 0;
        }
    }

    String::from_utf8(out).map_err(|err| err.to_string())
}
