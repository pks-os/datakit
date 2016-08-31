(* Implement API with direct GitHub API calls. *)

open Datakit_github
open Github_t
open Astring

type token = Github.Token.t

module PR = struct

  include PR

  let of_gh repo pr =
    let head = { Commit.repo; id = pr.pull_head.branch_sha } in
    { head;
      number = pr.pull_number;
      state  = pr.pull_state;
      title  = pr.pull_title;
    }

  let to_gh pr = {
    update_pull_title = Some pr.title;
    update_pull_body  = None;
    update_pull_state = Some pr.state;
  }

  let of_event repo pr =
    let id = pr.pull_request_event_pull_request.pull_head.branch_sha in
    let head = { Commit.repo; id } in
    {
      head;
      number = pr.pull_request_event_number;
      state  = pr.pull_request_event_pull_request.pull_state;
      title  = pr.pull_request_event_pull_request.pull_title;
    }

end

module Status = struct

  include Status

  let to_list = function
    | None   -> ["default"]
    | Some c -> String.cuts ~empty:false ~sep:"/" c

  let of_list = function
    | ["default"] -> None
    | l           -> Some (String.concat ~sep:"/" l)

  let of_gh commit s =
    { commit;
      context     = to_list s.status_context;
      url         = s.status_target_url;
      description = s.status_description;
      state       = s.status_state;
    }

  let to_gh s = {
    new_status_context     = of_list s.context;
    new_status_target_url  = s.url;
    new_status_description = s.description;
    new_status_state       = s.state;
  }

  let of_event repo s =
    let commit = { Commit.repo; id = s.status_event_sha } in
    { commit;
      context     = to_list s.status_event_context;
      url         = s.status_event_target_url;
      description = s.status_event_description;
      state       = s.status_event_state;
    }

end

module Ref = struct

  include Ref

  let to_list s = match String.cuts ~empty:false ~sep:"/" s with
    | "refs" :: l | l -> l

  let of_gh repo r =
    let head = { Commit.repo; id = r.git_ref_obj.obj_sha } in
    { head; name = to_list r.git_ref_name }

  let of_event repo r =
    let head = { Commit.repo; id = r.push_event_head } in
    { head; name = to_list r.push_event_ref }

end

module Event = struct

  include Event

  let of_gh e =
    let repo = match String.cut ~sep:"/" e.event_repo.repo_name with
      | None -> failwith (e.event_repo.repo_name ^ " is not a valid repo name")
      | Some (user, repo) -> { Repo.user; repo }
    in
    match e.event_payload with
    | `Status s       -> Status (Status.of_event repo s)
    | `PullRequest pr -> PR (PR.of_event repo pr)
    | `Push p         -> Ref (Ref.of_event repo p)
    | `Create _       -> Other "create"
    | `Delete _       -> Other "delete"
    | `Download       -> Other "download"
    | `Follow         -> Other "follow"
    | `Fork _         -> Other "fork"
    | `ForkApply      -> Other "fork-apply"
    | `Gist           -> Other "gist"
    | `Gollum _       -> Other "gollum"
    | `IssueComment _ -> Other "issue-comment"
    | `Issues _       -> Other "issues"
    | `Member _       -> Other "member"
    | `Public         -> Other "public"
    | `Release _      -> Other "release"
    | `Watch _        -> Other "watch"
    | `PullRequestReviewComment _ -> Other "pull-request-review-comment"
    | `CommitComment _            -> Other "commit-comment"

end

let event = Event.of_gh

open Rresult
open Lwt.Infix

type 'a result = ('a, string) Result.result Lwt.t

let run x =
  Lwt.catch
    (fun () -> Github.Monad.run x >|= fun x -> Ok x)
    (fun e -> Lwt.return (Error (Fmt.strf "Github: %s" (Printexc.to_string e))))

let user_exists token ~user =
  try
    Github.User.info ~token ~user ()
    |> run
    >|= R.map (fun _ -> true)
  with Github.Message _ ->
    Lwt.return (Ok false)

let repo_exists token { Repo.user; repo } =
  try
    Github.Repo.info ~token ~user ~repo ()
    |> run
    >|= R.map (fun _ -> true)
  with Github.Message _ ->
    Lwt.return (Ok false)

let repos token ~user =
  Github.User.repositories ~token ~user ()
  |> Github.Stream.to_list
  |> Github.Monad.map
  @@ List.map (fun r -> { Repo.user; repo = r.repository_name})
  |> run

let list_dedup f l =
  let tbl = Hashtbl.create (List.length l) in
  List.fold_left (fun acc s ->
      let x = f s in
      try let () = Hashtbl.find tbl x in acc
      with Not_found -> Hashtbl.add tbl x (); s :: acc
    ) [] l
  |> List.rev

let user_repo c = c.Commit.repo.Repo.user, c.Commit.repo.Repo.repo

let status token commit =
  let user, repo = user_repo commit in
  let git_ref = Commit.id commit in
  Github.Status.for_ref ~token ~user ~repo ~git_ref ()
  |> Github.Stream.to_list
  |> Github.Monad.map (fun l -> list_dedup (fun s -> s.status_context) l)
  |> Github.Monad.map (List.map (Status.of_gh commit))
  |> run

let set_status token status =
  let new_status = Status.to_gh status in
  let user, repo = user_repo (Status.commit status) in
  let sha = Status.commit_id status in
  Github.Status.create ~token ~user ~repo ~sha ~status:new_status ()
  |> run
  >|= R.map ignore

let user_repo pr = user_repo (PR.commit pr)

let set_pr token pr =
  let new_pr = PR.to_gh pr in
  let user, repo = user_repo pr in
  let num = PR.number pr in
  Github.Pull.update ~token ~user ~repo ~num ~update_pull:new_pr ()
  |> run
  >|= R.map ignore

let prs token r =
  let { Repo.user; repo } = r in
  Github.Pull.for_repo ~token ~state:`Open ~user ~repo ()
  |> Github.Stream.to_list
  |> Github.Monad.map @@ List.map (PR.of_gh r)
  |> run

let refs token r =
  let { Repo.user; repo } = r in
  let refs ty =
    Github.Repo.refs ~ty ~token ~user ~repo ()
    |> Github.Stream.to_list
    |> Github.Monad.map @@ List.map (Ref.of_gh r)
    |> run
  in
  let pp = R.pp ~ok:(Fmt.Dump.list Ref.pp) ~error:Fmt.string in
  refs "heads" >>= fun heads ->
  Logs.debug (fun l -> l "heads=%a" pp heads);
  refs "tags"  >|= fun tags  ->
  Logs.debug (fun l -> l "tags=%a" pp tags);
  match heads, tags with
  | Ok h, Ok t    -> Ok (h @ t)
  | Ok h, Error e
  | Error e, Ok h ->
    Logs.err (fun l -> l "refs: %s" e);
    Ok h
  | Error x, Error y -> Error (x ^ y)

let events token r =
  let { Repo.user; repo } = r in
  let events = Github.Event.for_repo ~token ~user ~repo () in
  Github.Stream.to_list events
  |> Github.Monad.map (List.map Event.of_gh)
  |> run
