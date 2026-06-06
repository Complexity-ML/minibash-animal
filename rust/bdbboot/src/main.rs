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
    println!("[bdbboot:rust] Altitude Linux BDB boot helper");

    let path = "/var/bdb/tables/services/data.bdb";
    let services = match read_bdb_rows(path, 8) {
        Ok(data) => data,
        Err(err) => {
            println!("[bdbboot:rust] cannot read {path}: {err}");
            return;
        }
    };

    let services: Vec<Service> = services.into_iter().filter_map(parse_service).collect();

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

fn parse_service(fields: Vec<String>) -> Option<Service> {
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

fn read_u32(buf: &[u8], off: &mut usize) -> Option<u32> {
    let bytes = buf.get(*off..*off + 4)?;
    *off += 4;
    Some(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

fn read_bdb_rows(path: &str, expected_cols: usize) -> Result<Vec<Vec<String>>, std::io::Error> {
    let buf = fs::read(path)?;
    let mut off = 0usize;
    if buf.get(0..4) != Some(b"BDB1") {
        return Ok(Vec::new());
    }
    off += 4;
    let version = read_u32(&buf, &mut off).unwrap_or(0);
    let cols = read_u32(&buf, &mut off).unwrap_or(0) as usize;
    let rows = read_u32(&buf, &mut off).unwrap_or(0) as usize;
    if version != 1 || cols != expected_cols {
        return Ok(Vec::new());
    }
    let mut out = Vec::with_capacity(rows);
    for _ in 0..rows {
        let mut row = Vec::with_capacity(cols);
        for _ in 0..cols {
            let len = read_u32(&buf, &mut off).unwrap_or(0) as usize;
            let bytes = match buf.get(off..off + len) {
                Some(bytes) => bytes,
                None => return Ok(Vec::new()),
            };
            off += len;
            row.push(String::from_utf8_lossy(bytes).into_owned());
        }
        out.push(row);
    }
    Ok(out)
}
